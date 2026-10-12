import Combine
import Foundation

struct RemoteModel: Identifiable, Equatable {
    var name: String
    var fileName: String
    var repository: String
    var sizeGB: Double
    /// Installed memory below which this model is not suggested.
    var minimumMemoryGB: Int
    var note: String

    var id: String { fileName }
    var url: URL { URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)")! }
}

/// Manages GGUF model files in ~/Library/Application Support/Typist/Models.
/// Any GGUF text model dropped into that folder can be selected.
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// Base (non-chat) models: plain continuation is what inline completion needs.
    static let catalog: [RemoteModel] = [
        RemoteModel(name: "Qwen3 0.6B Base", fileName: "Qwen3-0.6B-Base.i1-Q4_K_M.gguf", repository: "mradermacher/Qwen3-0.6B-Base-i1-GGUF",
                    sizeGB: 0.4, minimumMemoryGB: 8, note: "Fastest and lightest. Good on battery."),
        RemoteModel(name: "Qwen3 1.7B Base", fileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf", repository: "mradermacher/Qwen3-1.7B-Base-i1-GGUF",
                    sizeGB: 1.1, minimumMemoryGB: 8, note: "Balanced default for most Macs."),
        RemoteModel(name: "Gemma 3 1B", fileName: "gemma-3-1b-pt.i1-Q4_K_M.gguf", repository: "mradermacher/gemma-3-1b-pt-i1-GGUF",
                    sizeGB: 0.8, minimumMemoryGB: 8, note: "Small multilingual model. Gemma Terms of Use apply."),
        RemoteModel(name: "Qwen3 4B Base", fileName: "Qwen3-4B-Base.i1-Q4_K_M.gguf", repository: "mradermacher/Qwen3-4B-Base-i1-GGUF",
                    sizeGB: 2.5, minimumMemoryGB: 16, note: "Noticeably better suggestions; needs more memory."),
        RemoteModel(name: "Gemma 3 4B", fileName: "gemma-3-4b-pt.i1-Q4_K_M.gguf", repository: "mradermacher/gemma-3-4b-pt-i1-GGUF",
                    sizeGB: 2.5, minimumMemoryGB: 16, note: "Strong multilingual model. Gemma Terms of Use apply."),
        RemoteModel(name: "Qwen3 8B Base", fileName: "Qwen3-8B-Base.i1-Q4_K_M.gguf", repository: "mradermacher/Qwen3-8B-Base-i1-GGUF",
                    sizeGB: 5.0, minimumMemoryGB: 24, note: "Highest quality here; for Macs with plenty of memory."),
    ]

    static let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    /// The best catalog model this Mac comfortably runs.
    static var recommended: RemoteModel {
        if memoryGB >= 16 { return catalog[3] }
        return catalog[1]
    }

    let directory: URL
    @Published private(set) var installed: [URL] = []
    @Published private(set) var downloading: RemoteModel?
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    private var completion: ((URL) -> Void)?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    override init() {
        directory = AppPaths.support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
        refresh()
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        installed = files.filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func isInstalled(_ model: RemoteModel) -> Bool {
        installed.contains { $0.lastPathComponent == model.fileName }
    }

    func displayName(for url: URL) -> String {
        Self.catalog.first { $0.fileName == url.lastPathComponent }?.name ?? url.deletingPathExtension().lastPathComponent
    }

    /// The selected model if it still exists, otherwise the first installed one.
    func active(selected: String?) -> URL? {
        installed.first { $0.lastPathComponent == selected } ?? installed.first
    }

    func download(_ model: RemoteModel, completion: @escaping (URL) -> Void) {
        guard downloading == nil else { return }
        downloading = model
        progress = 0
        lastError = nil
        self.completion = completion
        task = session.downloadTask(with: model.url)
        task?.resume()
    }

    func cancelDownload() {
        task?.cancel()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Avoid redrawing UI for every network packet.
        if fraction - progress >= 0.005 { progress = fraction }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = downloading else { return }
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            return finish(error: "Download failed (HTTP \(status)).")
        }
        let target = directory.appendingPathComponent(model.fileName)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            let done = completion
            finish(error: nil)
            done?(target)
        } catch {
            finish(error: error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(error: (error as? URLError)?.code == .cancelled ? nil : "Download failed: \(error.localizedDescription)")
    }

    private func finish(error: String?) {
        guard downloading != nil else { return }
        downloading = nil
        completion = nil
        task = nil
        lastError = error
        refresh()
    }
}
