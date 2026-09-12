import AppKit
@preconcurrency import Vision

enum OCRServiceError: LocalizedError {
    case unreadableImage
    case noTextFound
    case recognitionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The screenshot could not be prepared for text recognition."
        case .noTextFound:
            return "No readable text was found in this screenshot."
        case .recognitionFailed(let error):
            return "Text recognition failed: \(error.localizedDescription)"
        }
    }
}

enum OCRService {
    static func recognizeText(in image: NSImage, completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            Task { @MainActor in completion(.failure(OCRServiceError.unreadableImage)) }
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            let result: Result<String, Error>
            if let error {
                result = .failure(OCRServiceError.recognitionFailed(error))
            } else {
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result = text.isEmpty ? .failure(OCRServiceError.noTextFound) : .success(text)
            }

            Task { @MainActor in completion(result) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                Task { @MainActor in completion(.failure(OCRServiceError.recognitionFailed(error))) }
            }
        }
    }
}
