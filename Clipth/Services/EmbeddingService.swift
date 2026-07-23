import Foundation
import NaturalLanguage

/// Wraps Apple's built-in sentence embeddings (NLEmbedding.sentenceEmbedding)
/// for cheap local semantic similarity. No download required — vectors are
/// shipped with the OS. Cross-language vectors are NOT comparable, so each
/// item stores the language it was embedded in. Search queries build one
/// vector per supported language and only compare compatible vector families.
///
/// **Thread safety**: CoreNLP is not thread-safe. All NLEmbedding work is
/// funneled through a single serial `DispatchQueue` to prevent heap
/// corruption crashes.
final class EmbeddingService: @unchecked Sendable {
    static let shared = EmbeddingService()

    private let queue = DispatchQueue(label: "com.wavever.clipth.embedding", qos: .utility)

    private init() {}

    struct Vector {
        let data: Data        // packed Float32
        let language: String  // NLLanguage.rawValue
        let dimension: Int
    }

    /// Compute an embedding for the given text. Thread-safe; the work runs on
    /// a dedicated serial queue. Returns nil for empty text or if no model is
    /// available for the detected language.
    func embed(_ text: String) -> Vector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snippet = String(trimmed.prefix(2_000))
        return queue.sync { _embed(snippet) }
    }

    /// Async variant for use in async contexts without blocking the caller.
    func embedAsync(_ text: String) async -> Vector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let snippet = String(trimmed.prefix(2_000))
        return await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self._embed(snippet))
            }
        }
    }

    private func _embed(_ snippet: String, using forcedLanguage: String? = nil) -> Vector? {
        let lang = forcedLanguage ?? normalizeLanguage(detectLanguage(snippet))
        guard let model = model(for: lang) else { return nil }

        // For Chinese we use word embeddings averaged across tokens. Apple's
        // Chinese *sentence* embedding is unreliable on short clipboard text
        // (returns near-identical vectors for "代码" and "斤斤计较"), while
        // the *word* embedding has discriminative per-token vectors. Averaging
        // them gives a phrase-level centroid that preserves the dominant word.
        let raw: [Double]?
        if lang == "zh" {
            raw = averagedTokenVector(snippet, language: .simplifiedChinese, model: model)
        } else {
            raw = model.vector(for: snippet)
        }
        guard let raw else { return nil }

        var floats = raw.map { Float($0) }
        let data = floats.withUnsafeMutableBufferPointer { buf -> Data in
            Data(buffer: buf)
        }
        return Vector(data: data, language: lang, dimension: floats.count)
    }

    private func averagedTokenVector(_ snippet: String, language: NLLanguage, model: NLEmbedding) -> [Double]? {
        let dim = model.dimension
        var sum = [Double](repeating: 0, count: dim)
        var hits = 0

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(language)
        tokenizer.string = snippet
        tokenizer.enumerateTokens(in: snippet.startIndex..<snippet.endIndex) { range, _ in
            let token = String(snippet[range])
            if let vec = model.vector(for: token), vec.count == dim {
                for i in 0..<dim { sum[i] += vec[i] }
                hits += 1
            }
            return true
        }

        if hits == 0 {
            // Fallback: try the whole snippet (handles vocab-OOV or very short
            // inputs the tokenizer didn't split usefully).
            return model.vector(for: snippet)
        }
        let inv = 1.0 / Double(hits)
        return sum.map { $0 * inv }
    }

    /// Search queries are short and often cross-language ("代码" for a Swift
    /// snippet, "meeting" for a Chinese note). Build vectors for each local
    /// model so ranking can compare against stored clips in either language.
    func embeddingsForSearch(_ text: String) -> [Vector] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let snippet = String(trimmed.prefix(2_000))
        return queue.sync {
            let preferred = normalizeLanguage(detectLanguage(snippet))
            let languages = ([preferred] + ["en", "zh"]).reduce(into: [String]()) { acc, lang in
                if !acc.contains(lang) { acc.append(lang) }
            }
            return languages.compactMap { _embed(snippet, using: $0) }
        }
    }

    /// Collapse fine-grained NLLanguage codes into the two families we have
    /// sentence models for: `zh` (any Chinese variant) and `en` (everything
    /// else). This also stabilizes short Latin-script snippets that
    /// NLLanguageRecognizer mislabels as `nl`, `da`, `id` etc.
    func normalizeLanguage(_ lang: NLLanguage) -> String {
        let raw = lang.rawValue
        if raw.hasPrefix("zh") { return "zh" }
        return "en"
    }

    /// Cosine similarity between two packed Float32 vectors. Returns 0 when
    /// either side is invalid or zero-magnitude.
    func cosineSimilarity(_ lhs: Data, _ rhs: Data) -> Float {
        guard lhs.count == rhs.count, lhs.count >= MemoryLayout<Float>.size else { return 0 }
        return lhs.withUnsafeBytes { lhsRaw -> Float in
            rhs.withUnsafeBytes { rhsRaw -> Float in
                let a = lhsRaw.bindMemory(to: Float.self)
                let b = rhsRaw.bindMemory(to: Float.self)
                let n = min(a.count, b.count)
                var dot: Float = 0
                var na: Float = 0
                var nb: Float = 0
                for i in 0..<n {
                    let x = a[i]
                    let y = b[i]
                    dot += x * y
                    na += x * x
                    nb += y * y
                }
                guard na > 0, nb > 0 else { return 0 }
                return dot / (sqrt(na) * sqrt(nb))
            }
        }
    }

    /// Pick the query vector that is compatible with an item's stored vector.
    /// Prefer the stored language tag, but tolerate legacy rows that only have
    /// vector bytes by falling back to a dimension match.
    func bestSimilarity(queryVectors: [Vector], itemEmbedding: Data?, itemLanguage: String?) -> Float? {
        guard let itemEmbedding else { return nil }
        if let itemLanguage,
           let query = queryVectors.first(where: {
               $0.language == itemLanguage && $0.data.count == itemEmbedding.count
           }) {
            return cosineSimilarity(query.data, itemEmbedding)
        }
        guard let query = queryVectors.first(where: { $0.data.count == itemEmbedding.count }) else {
            return nil
        }
        return cosineSimilarity(query.data, itemEmbedding)
    }

    func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    private var _modelCache: [String: NLEmbedding] = [:]

    /// Returns the embedding model used for the given normalized language.
    /// Chinese uses `wordEmbedding(for: .simplifiedChinese)` paired with
    /// per-token averaging (see `averagedTokenVector`); English uses the
    /// full sentence embedding. Cached per language because the dimensions
    /// differ between models and they aren't interchangeable.
    private func model(for normalizedLang: String) -> NLEmbedding? {
        if let cached = _modelCache[normalizedLang] { return cached }
        let loaded: NLEmbedding? = {
            switch normalizedLang {
            case "zh": return NLEmbedding.wordEmbedding(for: .simplifiedChinese)
            default:   return NLEmbedding.sentenceEmbedding(for: .english)
            }
        }()
        if let loaded {
            _modelCache[normalizedLang] = loaded
            return loaded
        }
        if normalizedLang != "en", let fallback = NLEmbedding.sentenceEmbedding(for: .english) {
            _modelCache[normalizedLang] = fallback
            return fallback
        }
        return nil
    }

    /// Expected vector dimension for a given normalized language, or nil if
    /// the model isn't available. Used to validate stored embeddings without
    /// hard-coding numbers that may differ between OS releases.
    func dimension(for normalizedLang: String) -> Int? {
        queue.sync {
            model(for: normalizedLang).map { $0.dimension }
        }
    }
}
