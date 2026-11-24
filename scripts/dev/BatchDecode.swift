import Foundation
import MLX
import MLXLMCommon

// Rows of different length, right-aligned: the mask hides a shorter row's leading padding, positions count its own tokens.
final class BatchAttentionCache: KVCache {
    private(set) var offset = 0
    private var keys: MLXArray
    private var values: MLXArray
    private var padding: [Int]
    private static let step = 256

    // Each row's keys and values as [1, heads, length, dimension].
    init(rows: [(keys: MLXArray, values: MLXArray)]) {
        let longest = rows.map { $0.keys.dim(2) }.max() ?? 0
        padding = rows.map { longest - $0.keys.dim(2) }
        func padded(_ array: MLXArray, by count: Int) -> MLXArray {
            guard count > 0 else { return array }
            var shape = array.shape
            shape[2] = count
            return concatenated([MLXArray.zeros(shape, dtype: array.dtype), array], axis: 2)
        }
        keys = concatenated(zip(rows, padding).map { padded($0.keys, by: $1) }, axis: 0)
        values = concatenated(zip(rows, padding).map { padded($0.values, by: $1) }, axis: 0)
        offset = longest
    }

    private var positions: [Int] { padding.map { offset - $0 } }

    var ropeOffset: RoPEOffset {
        let positions = positions
        return Set(positions).count == 1 ? .scalar(positions[0]) : .batch(MLXArray(positions.map(Int32.init)))
    }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let count = newKeys.dim(2)
        if offset + count > keys.dim(2) {
            let extra = ((count + Self.step - 1) / Self.step) * Self.step
            func grown(_ array: MLXArray) -> MLXArray {
                var shape = array.shape
                shape[2] = extra
                return concatenated([array[.ellipsis, ..<offset, 0...], MLXArray.zeros(shape, dtype: array.dtype)], axis: 2)
            }
            keys = grown(keys)
            values = grown(values)
        }
        keys[.ellipsis, offset ..< offset + count, 0...] = newKeys
        values[.ellipsis, offset ..< offset + count, 0...] = newValues
        offset += count
        return (keys[.ellipsis, ..<offset, 0...], values[.ellipsis, ..<offset, 0...])
    }

    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        precondition(n == 1 && windowSize == nil, "rows read their prompts alone; only decode steps run batched")
        guard padding.contains(where: { $0 > 0 }) else { return .none }
        let columns = MLXArray(Int32(0) ..< Int32(offset + n))[.newAxis]
        let starts = MLXArray(padding.map(Int32.init))[0..., .newAxis]
        return .array((columns .>= starts)[0..., .newAxis, .newAxis, 0...])
    }

    var state: [MLXArray] {
        get { [keys[.ellipsis, ..<offset, 0...], values[.ellipsis, ..<offset, 0...]] }
        set {
            keys = newValue[0]
            values = newValue[1]
            offset = keys.dim(2)
        }
    }

    var metaState: [String] {
        get { padding.map(String.init) }
        set { padding = newValue.compactMap { Int($0) } }
    }

    var maxSize: Int? { nil }
    var isTrimmable: Bool { false }
    func trim(_ n: Int) -> Int { 0 }
    func innerState() -> [MLXArray] { [keys, values] }
    func copy() -> any KVCache { fatalError("a batch cache is never copied") }

    // Keeps the given rows and drops the leading columns that are padding in all of them.
    func keep(_ rows: [Int]) {
        let index = MLXArray(rows.map(Int32.init))
        padding = rows.map { padding[$0] }
        let cut = padding.min() ?? 0
        keys = keys[index][.ellipsis, cut..., 0...]
        values = values[index][.ellipsis, cut..., 0...]
        padding = padding.map { $0 - cut }
        offset -= cut
    }
}

// What the model holds after reading an instruction, as LocalModelEngine keeps it; each row continues from a copy.
struct KeptInstruction {
    let tokens: [Int]
    let cache: [any KVCache]
    let state: LMOutput.State?

    init(reading tokens: [Int], with context: ModelContext, parameters: GenerateParameters) throws {
        let cache = try context.model.newCache(parameters: parameters)
        switch try context.model.prepare(LMInput(tokens: MLXArray(tokens)), cache: cache, state: nil, prefill: parameters.prefill) {
        case .tokens(let rest):
            state = context.model(rest[text: .newAxis], cache: cache, state: nil).state
        case .logits(let output):
            state = output.state
        }
        eval(cache)
        self.tokens = tokens
        self.cache = cache
    }
}

struct BatchReply {
    let tokens: [Int]
    let isCutOff: Bool
}

struct BatchRun {
    let replies: [BatchReply]
    // From the start to the first decode step's input: every row's prompt read and the rows merged.
    let firstStepSeconds: Double
    let seconds: Double
    let steps: Int
}

// Each row reads its prompt alone, as one clean-up does; only the decode steps run batched.
struct BatchDecoder {
    let context: ModelContext
    let stopTokens: Set<Int>

    init(context: ModelContext) {
        self.context = context
        var stops = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        if let unknown = context.tokenizer.unknownTokenId { stops.insert(unknown) }
        stopTokens = stops
    }

    func run(_ prompts: [[Int]], caps: [Int], from kept: KeptInstruction, parameters: GenerateParameters) throws -> BatchRun {
        let start = ContinuousClock.now
        let model = context.model
        var (cache, next) = try read(prompts, from: kept, parameters: parameters)
        let firstStep = seconds(since: start)

        var active = Array(prompts.indices)
        var tokens = Array(repeating: [Int](), count: prompts.count)
        var isCutOff = Array(repeating: false, count: prompts.count)
        var steps = 0
        while !active.isEmpty {
            try Task.checkCancellation()
            let current = next
            // The next step is queued before this one's tokens are read, as TokenIterator does.
            next = autoreleasepool {
                let logits = model(LMInput.Text(tokens: current[0..., .newAxis]), cache: cache, state: nil).logits
                let sampled = argMax(logits[0..., -1, 0...], axis: -1)
                asyncEval([sampled] + cache.flatMap(\.state))
                return sampled
            }
            steps += 1
            if steps % 256 == 0 { MLX.Memory.clearCache() }
            let read = current.asArray(Int.self)
            var kept: [Int] = []
            for (position, row) in active.enumerated() {
                let token = read[position]
                if stopTokens.contains(token) { continue }
                tokens[row].append(token)
                if tokens[row].count >= caps[row] {
                    isCutOff[row] = true
                } else {
                    kept.append(position)
                }
            }
            if kept.count < active.count, !kept.isEmpty {
                keep(kept, in: &cache)
                next = next[MLXArray(kept.map(Int32.init))]
            }
            active = kept.map { active[$0] }
        }
        // Lets the last queued step finish before its arrays are freed.
        eval(next)
        cache = []
        return BatchRun(
            replies: zip(tokens, isCutOff).map { BatchReply(tokens: $0, isCutOff: $1) },
            firstStepSeconds: firstStep, seconds: seconds(since: start), steps: steps
        )
    }

    // Every row's prompt read on its own copy of the instruction, then the rows merged, with each row's first token.
    private func read(_ prompts: [[Int]], from kept: KeptInstruction, parameters: GenerateParameters) throws -> ([any KVCache], MLXArray) {
        let model = context.model
        var rowCaches: [[any KVCache]] = []
        var firstTokens: [MLXArray] = []
        for prompt in prompts {
            precondition(prompt.starts(with: kept.tokens) && prompt.count > kept.tokens.count)
            let cache = kept.cache.map { $0.copy() }
            let input = LMInput(tokens: MLXArray(Array(prompt[kept.tokens.count...])))
            let logits = switch try model.prepare(input, cache: cache, state: kept.state, prefill: parameters.prefill) {
            case .tokens(let rest): model(rest[text: .newAxis], cache: cache, state: kept.state).logits
            case .logits(let output): output.logits
            }
            firstTokens.append(argMax(logits[0..., -1, 0...], axis: -1))
            rowCaches.append(cache)
        }
        let cache = try merged(rowCaches)
        let first = concatenated(firstTokens)
        eval([first] + cache.flatMap(\.state))
        return (cache, first)
    }

    private func merged(_ rows: [[any KVCache]]) throws -> [any KVCache] {
        guard rows.count > 1, let first = rows.first else { return rows.first ?? [] }
        return try first.indices.map { layer -> any KVCache in
            let unsupported = BatchDecodeError.unsupportedCache(String(describing: type(of: first[layer])))
            let mambas = rows.compactMap { $0[layer] as? MambaCache }
            if !mambas.isEmpty {
                let joined = MambaCache()
                for slot in 0 ..< 2 {
                    let parts = mambas.compactMap { $0[slot] }
                    guard mambas.count == rows.count, parts.count == rows.count else { throw unsupported }
                    joined[slot] = concatenated(parts, axis: 0)
                }
                return joined
            }
            guard first[layer] is KVCacheSimple else { throw unsupported }
            return BatchAttentionCache(rows: rows.map { row in
                let state = row[layer].state
                return (state[0], state[1])
            })
        }
    }

    private func keep(_ rows: [Int], in cache: inout [any KVCache]) {
        let index = MLXArray(rows.map(Int32.init))
        for layer in cache {
            if let mamba = layer as? MambaCache {
                mamba.filter(batchIndices: index)
            } else if let attention = layer as? BatchAttentionCache {
                attention.keep(rows)
            }
        }
    }
}

enum BatchDecodeError: Error {
    case unsupportedCache(String)
    case instructionNotRead
}
