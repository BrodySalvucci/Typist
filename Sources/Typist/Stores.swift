import Combine
import Foundation
import TypistCore

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Typist", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// User preferences, persisted in UserDefaults as one JSON blob.
final class SettingsStore: ObservableObject {
    private static let key = "preferences"

    @Published var prefs: Preferences {
        didSet {
            if prefs != oldValue { UserDefaults.standard.set(prefs.encoded(), forKey: Self.key) }
        }
    }

    init() {
        prefs = UserDefaults.standard.data(forKey: Self.key).map(Preferences.decode(from:)) ?? Preferences()
    }
}

/// A Codable value kept in a JSON file in Application Support, saved shortly after each change.
final class FileStore<Value: Codable>: ObservableObject {
    @Published var value: Value {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveWork: DispatchWorkItem?

    init(fileName: String, default defaultValue: Value) {
        url = AppPaths.support.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        value = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Value.self, from: $0) } ?? defaultValue
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable only by the user: this may contain their writing.
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// Shared objects, created once at launch.
final class AppState {
    static let shared = AppState()

    let settings = SettingsStore()
    let stats = FileStore(fileName: "stats.json", default: UsageStats())
    let samples = FileStore(fileName: "samples.json", default: WritingSamples())
    let models = ModelStore()
    let engine = LlamaEngine()
    let pause = PauseState()

    let engineStatus = EngineStatus()

    var prefs: Preferences { settings.prefs }

    /// Loads the selected model (or the first installed one) into the engine.
    func loadActiveModel() {
        guard let url = models.active(selected: prefs.selectedModel) else {
            engineStatus.phase = .noModel
            return
        }
        guard engineStatus.loadedFile != url.lastPathComponent || engineStatus.phase != .ready else { return }
        engineStatus.phase = .loading
        engineStatus.loadedFile = url.lastPathComponent
        engine.load(modelAt: url) { [weak self] error in
            guard let self, self.engineStatus.loadedFile == url.lastPathComponent else { return }
            self.engineStatus.phase = error.map { .failed($0.localizedDescription) } ?? .ready
            Log.debug("model \(url.lastPathComponent): \(self.engineStatus.phase)")
        }
    }

    func download(_ model: RemoteModel) {
        models.download(model) { [weak self] url in
            self?.settings.prefs.selectedModel = url.lastPathComponent
            self?.loadActiveModel()
        }
    }

    /// Pushes the user's vocabulary into the engine.
    func refreshPersonalization() {
        let active = prefs.recordWriting && prefs.personalizationStrength > 0
        engine.setPersonalization(words: active ? samples.value.vocabulary() : [:], strength: prefs.personalizationStrength)
    }
}

final class EngineStatus: ObservableObject {
    enum Phase: Equatable {
        case noModel, loading, ready
        case failed(String)
    }

    @Published var phase = Phase.noModel
    var loadedFile: String?
}

/// Temporary "off" switches that are not persisted.
final class PauseState: ObservableObject {
    @Published private(set) var globalUntil: Date?
    @Published private(set) var appsUntil: [String: Date] = [:]
    /// App switched off with Escape until the user leaves it.
    @Published var appOffUntilSwitch: String?

    func isPaused(app bundleID: String?) -> Bool {
        if let globalUntil, globalUntil > Date() { return true }
        guard let bundleID else { return false }
        if appOffUntilSwitch == bundleID { return true }
        if let until = appsUntil[bundleID], until > Date() { return true }
        return false
    }

    var globalRemaining: TimeInterval? {
        globalUntil.map { $0.timeIntervalSinceNow }.flatMap { $0 > 0 ? $0 : nil }
    }

    func appRemaining(_ bundleID: String?) -> TimeInterval? {
        bundleID.flatMap { appsUntil[$0] }.map { $0.timeIntervalSinceNow }.flatMap { $0 > 0 ? $0 : nil }
    }

    func pauseGlobally(for interval: TimeInterval) { globalUntil = Date().addingTimeInterval(interval) }
    func pause(app bundleID: String, for interval: TimeInterval) { appsUntil[bundleID] = Date().addingTimeInterval(interval) }

    func resumeGlobally() { globalUntil = nil }
    func resume(app bundleID: String) {
        appsUntil[bundleID] = nil
        if appOffUntilSwitch == bundleID { appOffUntilSwitch = nil }
    }
}
