import AppKit
import TypistCore

// `Typist --complete "Some text" [--model path.gguf]` prints a completion and
// exits. Handy for trying models and debugging without the UI.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--complete"), arguments.indices.contains(flag + 1) {
    let text = arguments[flag + 1]
    let modelPath = arguments.firstIndex(of: "--model").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    guard let model = modelPath.map(URL.init(fileURLWithPath:)) ?? ModelStore().active(selected: SettingsStore().prefs.selectedModel) else {
        FileHandle.standardError.write(Data("No model found. Pass --model <file.gguf>.\n".utf8))
        exit(1)
    }
    let engine = LlamaEngine()
    engine.load(modelAt: model) { error in
        if let error {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        let started = Date()
        engine.complete(prompt: PromptBuilder().build(before: text), options: GenerationOptions()) { result in
            let suggestion = result.flatMap { Suggestion.make(raw: $0.text, before: text, maxWords: 8, truncated: $0.truncated) }
            print(suggestion?.remaining ?? "(no confident suggestion)")
            FileHandle.standardError.write(Data(String(format: "%.0f ms\n", Date().timeIntervalSince(started) * 1000).utf8))
            engine.shutdown()
            exit(0)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()
