import AppKit
import ScreenCaptureKit
import Vision

/// Reads the text visible in the frontmost window (screenshot + on-device OCR)
/// so suggestions fit the email thread, chat or document being answered.
/// Images are processed in memory and never stored.
final class ScreenContext {
    private var cache: (pid: pid_t, text: String, date: Date)?
    private var inFlight = false
    /// Re-read the window at most this often.
    private let maxAge: TimeInterval = 20

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// The most recent text for the app, possibly slightly stale. Triggers a
    /// refresh in the background when needed; never blocks.
    func text(for pid: pid_t) -> String? {
        let fresh = cache.map { $0.pid == pid && Date().timeIntervalSince($0.date) < maxAge } ?? false
        if !fresh, !inFlight, Self.hasPermission {
            inFlight = true
            Task.detached(priority: .utility) {
                let text = await Self.recognizeText(pid: pid)
                DispatchQueue.main.async { [weak self] in
                    self?.inFlight = false
                    if let text { self?.cache = (pid, text, Date()) }
                }
            }
        }
        return cache?.pid == pid ? cache?.text : nil
    }

    private static func recognizeText(pid: pid_t) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil, let observations = request.results else { return nil }
        // Vision's origin is bottom-left: sort top to bottom, then left to right.
        let lines = observations
            .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { $0.count > 2 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
