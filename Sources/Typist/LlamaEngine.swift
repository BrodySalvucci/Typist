import Foundation
import llama

struct GenerationOptions {
    var maxTokens = 24
    var maxWords = 8
    /// Don't suggest anything if the model is less sure than this about the first token.
    var minFirstTokenProbability: Float = 0.15
    /// Stop extending the suggestion once the model's confidence drops below this.
    var minTokenProbability: Float = 0.08

    /// - Parameter eagerness: 0 = only very sure suggestions, 1 = suggest eagerly.
    init(maxWords: Int = 8, eagerness: Double = 0.5) {
        self.maxWords = maxWords
        maxTokens = max(maxWords * 3, 6)
        let caution = Float(1 - min(max(eagerness, 0), 1))
        minFirstTokenProbability = 0.02 + 0.2 * caution
        minTokenProbability = 0.01 + 0.1 * caution
    }
}

struct GenerationResult {
    var text: String
    /// Generation stopped because of the token limit (last word may be partial).
    var truncated: Bool
}

enum EngineError: LocalizedError {
    case modelLoadFailed(String)
    case contextCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Could not load model at \(path)"
        case .contextCreationFailed: return "Could not create an inference context"
        }
    }
}

/// Greedy text continuation on top of llama.cpp.
///
/// All llama calls happen on one serial queue. Each new request supersedes the
/// previous one, and the KV cache is reused for the shared prompt prefix, so a
/// keystroke usually costs one or two token evaluations rather than a full
/// prompt pass.
final class LlamaEngine {
    private let queue = DispatchQueue(label: "typist.llama", qos: .userInitiated)
    private let lock = NSLock()
    private var latestRequest = 0

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Tokens currently held in the context's KV cache (sequence 0).
    private var cached: [llama_token] = []
    /// Words to favor, with weights 0...1, and the strength to apply them with.
    private var favoredWords: [String: Double] = [:]
    private var biasStrength: Float = 0
    /// Logit bonus per token, derived from `favoredWords` for the loaded model.
    private var tokenBias: [llama_token: Float] = [:]

    private static let contextLength: UInt32 = 4096
    private static let backendInit: Void = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// Main-thread state.
    private(set) var isLoaded = false

    func load(modelAt url: URL, completion: @escaping (Error?) -> Void) {
        isLoaded = false
        queue.async {
            _ = Self.backendInit
            self.unloadLocked()

            var modelParams = llama_model_default_params()
            modelParams.n_gpu_layers = 999
            guard let model = llama_model_load_from_file(url.path, modelParams) else {
                return DispatchQueue.main.async { completion(EngineError.modelLoadFailed(url.path)) }
            }
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = Self.contextLength
            contextParams.n_batch = Self.contextLength
            guard let context = llama_init_from_model(model, contextParams) else {
                llama_model_free(model)
                return DispatchQueue.main.async { completion(EngineError.contextCreationFailed) }
            }
            self.model = model
            self.context = context
            self.vocab = llama_model_get_vocab(model)
            self.rebuildTokenBias()
            DispatchQueue.main.async {
                self.isLoaded = true
                completion(nil)
            }
        }
    }

    /// Frees the model synchronously. llama.cpp's Metal backend asserts at
    /// process exit if a model is still alive, so call this before quitting.
    func shutdown() {
        cancel()
        isLoaded = false
        queue.sync { unloadLocked() }
    }

    /// Invalidates any in-flight request.
    func cancel() {
        lock.withLock { latestRequest += 1 }
    }

    /// Continues `prompt`. `completion` is called on the main queue with `nil`
    /// when superseded, not confident, or no model is loaded.
    func complete(prompt: String, options: GenerationOptions, completion: @escaping (GenerationResult?) -> Void) {
        let id = lock.withLock { () -> Int in
            latestRequest += 1
            return latestRequest
        }
        queue.async {
            let result = self.generate(prompt: prompt, options: options) {
                self.lock.withLock { self.latestRequest } != id
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Nudges generation toward words the user writes often.
    /// - Parameters:
    ///   - words: Word to weight (0...1).
    ///   - strength: 0 turns the effect off; 1 is strong.
    func setPersonalization(words: [String: Double], strength: Double) {
        queue.async {
            self.favoredWords = words
            self.biasStrength = Float(strength)
            self.rebuildTokenBias()
        }
    }

    /// Words that could come next after `prompt`, most likely first. Each keeps
    /// its leading space if the model would put one there. Used to offer
    /// replacements for a selected word and alternatives to a suggestion.
    func alternatives(prompt: String, excluding: String, count: Int, completion: @escaping ([String]) -> Void) {
        let id = lock.withLock { () -> Int in
            latestRequest += 1
            return latestRequest
        }
        queue.async {
            let words = self.generateAlternatives(prompt: prompt, excluding: excluding, count: count) {
                self.lock.withLock { self.latestRequest } != id
            }
            DispatchQueue.main.async { completion(words) }
        }
    }

    // MARK: - Queue-confined

    private func rebuildTokenBias() {
        tokenBias = [:]
        guard vocab != nil, biasStrength > 0 else { return }
        for (word, weight) in favoredWords {
            // Mid-sentence words start with a space in most vocabularies.
            guard let token = tokenize(" " + word, addSpecial: false).first else { continue }
            tokenBias[token] = max(tokenBias[token] ?? 0, Float(weight) * biasStrength * 2.5)
        }
    }

    /// Evaluates `prompt`, reusing the cached prefix. Returns the number of prompt tokens.
    private func prime(with prompt: String, reserve: Int) -> Int? {
        guard let context else { return nil }
        var tokens = tokenize(prompt, addSpecial: true)
        let limit = Int(Self.contextLength) - reserve - 1
        if tokens.count > limit {
            tokens.removeFirst(tokens.count - limit)
        }
        guard !tokens.isEmpty else { return nil }

        // Always re-evaluate at least the last token so fresh logits are available.
        var shared = zip(tokens, cached).prefix { $0 == $1 }.count
        shared = min(shared, tokens.count - 1)
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, llama_pos(shared), -1) {
            llama_memory_clear(memory, true)
            shared = 0
        }
        cached = Array(tokens[..<shared])

        var pending = Array(tokens[shared...])
        return decode(&pending) ? tokens.count : nil
    }

    private func generateAlternatives(prompt: String, excluding: String, count: Int, isCancelled: () -> Bool) -> [String] {
        guard let context, let vocab, !isCancelled() else { return [] }
        var text = prompt
        while text.last == " " { text.removeLast() }
        guard let promptLength = prime(with: text, reserve: 8),
              let logits = llama_get_logits_ith(context, -1) else { return [] }

        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        let ranked = (0..<vocabSize).sorted { logits[$0] > logits[$1] }.prefix(count * 4).map { llama_token($0) }

        var results: [String] = []
        let excluded = excluding.lowercased()
        for candidate in ranked {
            if isCancelled() { return [] }
            if results.count == count { break }
            if llama_vocab_is_eog(vocab, candidate) || llama_vocab_is_control(vocab, candidate) { continue }

            // Rewind to the end of the prompt, then spell out the rest of the word.
            guard llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(promptLength), -1) else { break }
            cached = Array(cached.prefix(promptLength))
            var bytes = piece(for: candidate)
            var next = [candidate]
            for _ in 0..<4 {
                guard decode(&next), let logits = llama_get_logits_ith(context, -1) else { break }
                let (token, _) = mostLikely(logits: logits, count: vocabSize)
                let piece = self.piece(for: token)
                guard let first = piece.first, Character(UnicodeScalar(first)).isLetter || first >= 0x80 || first == UInt8(ascii: "'") else { break }
                bytes.append(contentsOf: piece)
                next = [token]
            }
            let raw = String(decoding: bytes, as: UTF8.self)
            let word = raw.trimmingCharacters(in: .whitespaces)
            let entry = (raw.first == " " ? " " : "") + word
            guard word.count >= 2, word.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }),
                  word.lowercased() != excluded, !results.contains(where: { $0.lowercased() == entry.lowercased() }) else { continue }
            results.append(entry)
        }
        return results
    }

    private func unloadLocked() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        vocab = nil
        cached = []
    }

    private func generate(prompt: String, options: GenerationOptions, isCancelled: () -> Bool) -> GenerationResult? {
        guard let context, let vocab, !isCancelled() else { return nil }

        guard prime(with: prompt, reserve: options.maxTokens) != nil else { return nil }

        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var bytes: [UInt8] = []
        var truncated = true

        for step in 0..<options.maxTokens {
            if isCancelled() { return nil }
            guard let logits = llama_get_logits_ith(context, -1) else { return nil }

            let (token, probability) = mostLikely(logits: logits, count: vocabSize)
            if step == 0, probability < options.minFirstTokenProbability {
                Log.debug("engine: first token p=\(probability) below \(options.minFirstTokenProbability)")
                return nil
            }
            if probability < options.minTokenProbability
                || llama_vocab_is_eog(vocab, token)
                || llama_vocab_is_control(vocab, token) {
                truncated = false
                break
            }

            let piece = self.piece(for: token)
            if let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                bytes.append(contentsOf: piece[..<newline])
                truncated = false
                break
            }
            bytes.append(contentsOf: piece)

            let words = String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isWhitespace).count
            if words > options.maxWords {
                truncated = false
                break
            }

            var next = [token]
            guard decode(&next) else { break }
        }

        // The cache now also contains generated tokens; they are trimmed by
        // the shared-prefix logic on the next request.
        let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "")
        return GenerationResult(text: text, truncated: truncated)
    }

    private func decode(_ tokens: inout [llama_token]) -> Bool {
        let count = Int32(tokens.count)
        let status = tokens.withUnsafeMutableBufferPointer {
            llama_decode(context, llama_batch_get_one($0.baseAddress, count))
        }
        guard status == 0 else {
            llama_memory_clear(llama_get_memory(context), true)
            cached = []
            return false
        }
        cached.append(contentsOf: tokens)
        return true
    }

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString.dropLast())
        guard !utf8.isEmpty else { return [] }
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        let count = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, Int32(tokens.count), addSpecial, false)
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }

    /// The most likely token (after personalization bias) and its softmax probability.
    private func mostLikely(logits: UnsafePointer<Float>, count: Int) -> (llama_token, Float) {
        var best = 0
        var maximum = logits[0]
        for index in 1..<count where logits[index] > maximum {
            maximum = logits[index]
            best = index
        }
        var sum: Float = 0
        for index in 0..<count {
            sum += exp(logits[index] - maximum)
        }
        var bestScore = maximum
        for (token, bonus) in tokenBias where Int(token) < count && logits[Int(token)] + bonus > bestScore {
            bestScore = logits[Int(token)] + bonus
            best = Int(token)
        }
        return (llama_token(best), exp(logits[best] - maximum) / sum)
    }
}
