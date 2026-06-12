import AppKit
import Vision

/// Runs Vision text recognition on an image file and returns the joined
/// recognized strings. Uses accurate-level recognition with automatic language
/// detection and language correction enabled.
///
/// All work runs on a background queue; the completion is delivered on the
/// main queue so callers can update UI directly.
enum OCRService {

    // MARK: - Public API

    /// Recognized text result. `text` is nil only on a hard Vision failure;
    /// empty-string means Vision ran successfully but found no text.
    enum RecognitionResult {
        case success(String)
        case failure(Error)
    }

    /// Recognize text in the image at `imageURL`.
    /// - Parameters:
    ///   - imageURL: File URL of any image Vision can decode (PNG, JPEG, etc.).
    ///   - completion: Called on the **main queue** with the result.
    static func recognizeText(
        in imageURL: URL,
        completion: @escaping (RecognitionResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performRecognition(imageURL: imageURL)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Implementation

    private static func performRecognition(imageURL: URL) -> RecognitionResult {
        guard let cgImage = loadCGImage(from: imageURL) else {
            return .failure(OCRError.imageLoadFailed(imageURL))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Automatic language detection: pass an empty array so Vision picks
        // all supported languages rather than filtering to a fixed set.
        request.recognitionLanguages = []

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(error)
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return .success(lines.joined(separator: "\n"))
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}

// MARK: - Errors

enum OCRError: LocalizedError {
    case imageLoadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Could not load image for text recognition: \(url.lastPathComponent)"
        }
    }
}
