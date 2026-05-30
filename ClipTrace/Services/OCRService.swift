import Foundation
import Vision
import AppKit

/// A single recognized text fragment together with its bounding box in
/// normalized image coordinates (origin at bottom-left, values 0–1).
struct OCRFragment: Identifiable {
    let id = UUID()
    let text: String
    /// Normalized bounding box from Vision (origin = bottom-left of image).
    let boundingBox: CGRect
    /// Confidence from the top candidate (0–1).
    let confidence: Float
}

/// Offline OCR for clipboard images using the Vision framework. Recognition
/// runs on a detached background task so the calling view can `await` without
/// blocking the main actor, and the request is configured for the languages
/// our users are most likely to clip: Chinese (Simplified + Traditional)
/// and English.
final class OCRService {
    static let shared = OCRService()

    private init() {}

    // MARK: - Plain-text convenience (used elsewhere)

    /// Run OCR against an image-typed `ClipboardItem`. Returns the recognized
    /// text joined by newlines, or an empty string when no text was found or
    /// the image cannot be decoded.
    func recognize(item: ClipboardItem) async -> String {
        if let data = item.imageData {
            return await recognize(imageData: data)
        }
        if let url = item.resolvedFileURL,
           let data = try? Data(contentsOf: url) {
            return await recognize(imageData: data)
        }
        return ""
    }

    func recognize(imageData: Data) async -> String {
        let fragments = await recognizeFragments(imageData: imageData)
        return fragments.map(\.text).joined(separator: "\n")
    }

    // MARK: - Fragment-level API (used by the live-text overlay)

    /// Run OCR and return individual text fragments with their bounding boxes.
    func recognizeFragments(item: ClipboardItem) async -> [OCRFragment] {
        if let data = item.imageData {
            return await recognizeFragments(imageData: data)
        }
        if let url = item.resolvedFileURL,
           let data = try? Data(contentsOf: url) {
            return await recognizeFragments(imageData: data)
        }
        return []
    }

    func recognizeFragments(imageData: Data) async -> [OCRFragment] {
        await Task.detached(priority: .userInitiated) { () -> [OCRFragment] in
            guard let image = NSImage(data: imageData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return []
            }
            return Self.performOCR(cgImage: cgImage)
        }.value
    }

    // MARK: - Vision

    private static func performOCR(cgImage: CGImage) -> [OCRFragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations.compactMap { obs -> OCRFragment? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRFragment(
                text: candidate.string,
                boundingBox: obs.boundingBox,
                confidence: candidate.confidence
            )
        }
    }
}
