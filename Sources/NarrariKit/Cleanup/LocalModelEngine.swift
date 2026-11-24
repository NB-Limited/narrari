import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public actor LocalModelEngine: CleanupEngine {
    public nonisolated let name: String
    public nonisolated let runsInApp = true
    public private(set) var state = ModelState.missing

    // Enough for the buffers a short reply reuses; anything freed beyond it goes back to the system between dictations.
    private static let gpuCacheLimit = 32 * 1024 * 1024

    private let model: ModelReference
    private let hub: ModelHub
    private let onStateChange: @Sendable (ModelState) -> Void
    private var loaded: Loaded?
    private var loading: Task<Loaded, any Error>?
    private var loadGeneration = 0
    private var wasLoaded = false
    private var decoding: Task<Void, Never>?

    public init(
        model: ModelReference,
        store: ModelStore,
        onStateChange: @escaping @Sendable (ModelState) -> Void = { _ in }
    ) {
        name = model.id
        self.model = model
        hub = ModelHub(store: store)
        self.onStateChange = onStateChange
    }

    public func load() async throws {
        _ = try await loadedModel()
    }

    // A generation stopped by its time limit or by the user still runs its last step; quitting under it trips Metal.
    public func unload() async {
        loading?.cancel()
        loading = nil
        decoding?.cancel()
        await decoding?.value
        loaded = nil
        report(.missing)
    }

    // Download progress goes to onStateChange alone, from the hub's thread; every other state goes through here.
    private func report(_ new: ModelState) {
        state = new
        onStateChange(new)
    }

    public func delete() async throws {
        await unload()
        wasLoaded = false
        let directory = try hub.directory(of: name)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public nonisolated func bytesOnDisk() throws -> Int64 {
        try ModelStore.bytes(in: hub.directory(of: name))
    }

    public func rewrite(_ transcript: String, instruction: String, growth: ReplyGrowth) async throws -> String {
        let loaded = try await loadedModel()
        let reply: (text: String, isCutOff: Bool)
        do {
            reply = try await generate(on: loaded, instruction: instruction, transcript: transcript, growth: growth)
        } catch let error as CancellationError {
            throw error
        } catch let error as CleanupEngineError {
            throw error
        } catch {
            Log.failure("cleanup-generate", error: error)
            throw CleanupEngineError.generationFailed()
        }
        guard !reply.isCutOff else {
            Log.event("cleanup-reply-cut-off")
            throw CleanupEngineError.replyTooLong
        }
        return reply.text
    }

    private func warm(_ loaded: Loaded) async {
        do {
            _ = try await generate(on: loaded, instruction: "Repeat the text.", transcript: "Ready.", growth: nil)
        } catch {
            Log.failure("cleanup-warm", error: error)
        }
    }

    private func generate(
        on loaded: Loaded,
        instruction: String,
        transcript: String,
        growth: ReplyGrowth?
    ) async throws -> (text: String, isCutOff: Bool) {
        let container = loaded.container
        let reasoning = await container.configuration.reasoningConfig
        let thinkingOff: [String: any Sendable]?
        do {
            thinkingOff = try reasoning?.promptStrategy.additionalContext(forThinkingEnabled: false)
        } catch {
            throw CleanupEngineError.generationFailed()
        }

        let tokenizer = await container.tokenizer
        let cap = growth?.tokenLimit(for: tokenizer.encode(text: transcript, addSpecialTokens: false).count) ?? 1
        let parameters = GenerateParameters(
            maxTokens: cap, temperature: 0, presencePenalty: growth?.repeatPenalty, presenceContextSize: ReplyGrowth.repeatWindow
        )
        await decoding?.value
        let (stream, decode) = try await container.perform { [loaded] context in
            func prompt(_ text: String) async throws -> LMInput {
                try await context.processor.prepare(
                    input: UserInput(chat: [.system(instruction), .user(text)], additionalContext: thinkingOff)
                )
            }
            let input = try await prompt(transcript)
            let tokens = input.text.tokens.asArray(Int.self)
            let kept = try await loaded.prefixes.state(for: tokens) {
                // Two prompts that differ only in the dictated text share exactly the instruction part.
                let one = try await prompt("alpha").text.tokens.asArray(Int.self)
                let other = try await prompt("omega").text.tokens.asArray(Int.self)
                return zip(one, other).prefix { $0 == $1 }.map(\.0)
            } build: { instructionTokens in
                try InstructionState(reading: instructionTokens, with: context, parameters: parameters)
            }
            let iterator = if let kept {
                try TokenIterator(
                    input: LMInput(tokens: MLXArray(Array(tokens[kept.prefixLength...]))), model: context.model,
                    cache: kept.state.cache, state: kept.state.modelState, parameters: parameters
                )
            } else {
                try TokenIterator(input: input, model: context.model, parameters: parameters)
            }
            return generateTask(
                promptTokenCount: tokens.count, modelConfiguration: context.configuration,
                tokenizer: context.tokenizer, iterator: iterator
            )
        }
        decoding = decode
        return try await reply(from: stream, reasoning: reasoning, logsSpeed: growth != nil)
    }

    private func reply(
        from stream: AsyncStream<Generation>, reasoning: ReasoningConfig?, logsSpeed: Bool
    ) async throws -> (text: String, isCutOff: Bool) {
        var reply = ""
        var info: GenerateCompletionInfo?
        for await event in stream {
            if let chunk = event.chunk { reply += chunk }
            if let done = event.info { info = done }
        }
        try Task.checkCancellation()
        // An unload stops a generation that a dictation may still be waiting for; its half reply is not a reply.
        guard let info, info.stopReason != .cancelled else { throw CancellationError() }
        if logsSpeed {
            Log.count("cleanup-reply-tokens", info.generationTokenCount)
            Log.count("cleanup-tokens-per-second", Int(info.tokensPerSecond.rounded()))
        }

        if let reasoning, reply.contains(reasoning.startDelimiter) || reply.contains(reasoning.endDelimiter) {
            throw CleanupEngineError.generationFailed()
        }
        return (reply, info.stopReason == .length)
    }

    private func loadedModel() async throws -> Loaded {
        if let loaded { return loaded }
        return try await (loading ?? startLoading()).value
    }

    // The load records its own result and warms the model once, so every caller waiting on it gets the same answer.
    // A load cancelled by unload leaves the state unload set, and never clears a newer load that started since.
    private func startLoading() -> Task<Loaded, any Error> {
        let hub = hub
        let model = model
        let onStateChange = onStateChange
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task {
            defer { if loadGeneration == generation { loading = nil } }
            // A model on disk only loads into memory, and the clean-up waits for it within its time limit.
            report(.preparing(fraction: wasLoaded || hub.cachedModelIDs().contains(model.id) ? 1 : 0))
            let started = ContinuousClock.now
            do {
                var configuration = LLMModelFactory.shared.configuration(id: model.id)
                configuration.id = .id(model.id, revision: model.revision)
                let container = try await LLMModelFactory.shared.loadContainer(
                    from: hub, using: TokenizerFiles(), configuration: configuration
                ) { progress in
                    // The hub reports file downloads only; loading the weights afterwards has no progress.
                    onStateChange(.preparing(fraction: progress.fractionCompleted, isDownloading: progress.fractionCompleted < 1))
                }
                try Task.checkCancellation()
                Memory.cacheLimit = Self.gpuCacheLimit
                // MLX keeps compiled traces per thread but drops them on the thread that frees the model, so a reloaded
                // model could run the unloaded one's traces and weights: wrong replies, and 90 to 240 MB kept per reload.
                MLX.compile(enable: false)
                let loaded = Loaded(container: container)
                await warm(loaded)
                let took = (ContinuousClock.now - started) / .seconds(1)
                if wasLoaded { Log.timing("cleanup-model-reload", seconds: took) } else { Log.timing("cleanup-model-load", seconds: took) }
                self.loaded = loaded
                wasLoaded = true
                report(.ready)
                return loaded
            } catch {
                if Task.isCancelled { throw CancellationError() }
                Log.failure("cleanup-model-load", error: error)
                let failure = error as? CleanupEngineError ?? .modelUnavailable
                report(.failed(failure.problem))
                throw failure
            }
        }
        loading = task
        return task
    }
}

// The kept prefix is read and written only inside the container's perform, which lets one call in at a time.
private struct Loaded: @unchecked Sendable {
    let container: ModelContainer
    let prefixes = PromptPrefixCache<InstructionState> { $0.copy() }
}

// What the model holds after reading an instruction; each dictation continues from its own copy.
private struct InstructionState {
    let cache: [any KVCache]
    let modelState: LMOutput.State?

    init(cache: [any KVCache], modelState: LMOutput.State?) {
        self.cache = cache
        self.modelState = modelState
    }

    init(reading tokens: [Int], with context: ModelContext, parameters: GenerateParameters) throws {
        let cache = try context.model.newCache(parameters: parameters)
        let input = LMInput(tokens: MLXArray(tokens))
        switch try context.model.prepare(input, cache: cache, state: nil, prefill: parameters.prefill) {
        case .tokens(let rest):
            modelState = context.model(rest[text: .newAxis], cache: cache, state: nil).state
        case .logits(let output):
            modelState = output.state
        }
        eval(cache)
        self.cache = cache
    }

    func copy() -> InstructionState {
        InstructionState(cache: cache.map { $0.copy() }, modelState: modelState)
    }
}
