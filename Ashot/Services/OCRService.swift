import AppKit
@preconcurrency import Vision

enum OCRServiceError: LocalizedError {
    case unreadableImage, noTextFound, noBarcodeFound
    nonisolated var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The screenshot could not be prepared for recognition."
        case .noTextFound: return "No readable text was found in this image."
        case .noBarcodeFound: return "No barcode was found in this image."
        }
    }
}

/// Vision requests support cancellation. UI task IDs additionally prevent a late callback from
/// replacing a newer result. Completion is delivered exactly once on the main actor.
final class RecognitionJob {
    private let request: VNRequest
    init(_ request: VNRequest) { self.request = request }
    func cancel() { request.cancel() }
}

enum OCRService {
    @discardableResult
    static func recognizeText(in image: NSImage, completion: @escaping @MainActor (Result<String, Error>) -> Void) -> RecognitionJob? {
        guard let snapshot = CapturedImageSnapshot(image: image) else { completion(.failure(OCRServiceError.unreadableImage)); return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let preference = UserDefaults.standard.string(forKey: "ocrLanguage") ?? "auto"
        if preference == "zh-Hans" { request.recognitionLanguages = ["zh-Hans", "en-US"] }
        else if preference == "en" { request.recognitionLanguages = ["en-US"] }
        else { request.automaticallyDetectsLanguage = true }
        let job = RecognitionJob(request)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do {
                try VNImageRequestHandler(cgImage: snapshot.cgImage).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                result = text.isEmpty ? .failure(OCRServiceError.noTextFound) : .success(text)
            } catch { result = .failure(error) }
            Task { @MainActor in completion(result) }
        }
        return job
    }

    @discardableResult
    static func recognizeBarcodes(in image: NSImage, completion: @escaping @MainActor (Result<String, Error>) -> Void) -> RecognitionJob? {
        guard let snapshot = CapturedImageSnapshot(image: image) else { completion(.failure(OCRServiceError.unreadableImage)); return nil }
        let request = VNDetectBarcodesRequest()
        let job = RecognitionJob(request)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do {
                try VNImageRequestHandler(cgImage: snapshot.cgImage).perform([request])
                let text = (request.results ?? []).compactMap(\.payloadStringValue).joined(separator: "\n")
                result = text.isEmpty ? .failure(OCRServiceError.noBarcodeFound) : .success(text)
            } catch { result = .failure(error) }
            Task { @MainActor in completion(result) }
        }
        return job
    }
}
