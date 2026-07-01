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
        await recognize(reference: ImagePayloadStore.reference(for: item))
    }

    func recognize(reference: ImagePayloadStore.Reference) async -> String {
        if let payload = await ImagePayloadStore.payloadAsync(for: reference) {
            return await recognize(imageData: payload.data)
        }
        if let url = reference.fileURL,
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
        await recognizeFragments(reference: ImagePayloadStore.reference(for: item))
    }

    func recognizeFragments(reference: ImagePayloadStore.Reference) async -> [OCRFragment] {
        if let payload = await ImagePayloadStore.payloadAsync(for: reference) {
            return await recognizeFragments(imageData: payload.data)
        }
        if let url = reference.fileURL,
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

/// A QR code / barcode recognized in an image, with the payload and Vision
/// bounding box kept together so the UI can highlight the exact source area.
struct BarcodeDetection: Identifiable, Hashable {
    let id = UUID()
    let payload: String
    let symbology: String
    /// Normalized bounding box from Vision (origin = bottom-left of image).
    let boundingBox: CGRect
    /// Confidence from Vision (0–1).
    let confidence: Float

    var displaySymbology: String {
        switch symbology.uppercased() {
        case "QR": return "QR Code"
        case "AZTEC": return "Aztec"
        case "CODABAR": return "Codabar"
        case "CODE39": return "Code 39"
        case "CODE39CHECKSUM": return "Code 39 Checksum"
        case "CODE39FULLASCII": return "Code 39 Full ASCII"
        case "CODE39FULLASCIICHECKSUM": return "Code 39 Full ASCII Checksum"
        case "CODE93": return "Code 93"
        case "CODE93I": return "Code 93i"
        case "CODE128": return "Code 128"
        case "DATAMATRIX": return "Data Matrix"
        case "EAN8": return "EAN-8"
        case "EAN13": return "EAN-13"
        case "GS1DATABAR": return "GS1 DataBar"
        case "GS1DATABAREXPANDED": return "GS1 DataBar Expanded"
        case "GS1DATABARLIMITED": return "GS1 DataBar Limited"
        case "I2OF5": return "Interleaved 2 of 5"
        case "I2OF5CHECKSUM": return "Interleaved 2 of 5 Checksum"
        case "ITF14": return "ITF-14"
        case "MICROPDF417": return "MicroPDF417"
        case "MICROQR": return "Micro QR"
        case "PDF417": return "PDF417"
        case "UPCE": return "UPC-E"
        default:
            return symbology
                .replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Offline QR code / barcode decoding for clipboard images using Vision.
/// Supports QR plus the 1D/2D barcode formats available on the current macOS
/// release (EAN/UPC, Code 39/93/128, Data Matrix, PDF417, Aztec, etc.).
final class BarcodeService {
    static let shared = BarcodeService()

    private init() {}

    func detect(item: ClipboardItem) async -> [BarcodeDetection] {
        await detect(reference: ImagePayloadStore.reference(for: item))
    }

    func detect(reference: ImagePayloadStore.Reference) async -> [BarcodeDetection] {
        if let payload = await ImagePayloadStore.payloadAsync(for: reference) {
            return await detect(imageData: payload.data)
        }
        if let url = reference.fileURL,
           let data = try? Data(contentsOf: url) {
            return await detect(imageData: data)
        }
        return []
    }

    func detect(imageData: Data) async -> [BarcodeDetection] {
        await Task.detached(priority: .userInitiated) { () -> [BarcodeDetection] in
            guard let image = NSImage(data: imageData),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return []
            }
            return Self.performBarcodeDetection(cgImage: cgImage)
        }.value
    }

    private static func performBarcodeDetection(cgImage: CGImage) -> [BarcodeDetection] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        return observations
            .compactMap { obs -> BarcodeDetection? in
                guard let payload = obs.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty else {
                    return nil
                }
                return BarcodeDetection(
                    payload: payload,
                    symbology: obs.symbology.rawValue,
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence
                )
            }
            .sorted { lhs, rhs in
                let lhsTop = lhs.boundingBox.maxY
                let rhsTop = rhs.boundingBox.maxY
                if abs(lhsTop - rhsTop) > 0.01 { return lhsTop > rhsTop }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
    }
}
