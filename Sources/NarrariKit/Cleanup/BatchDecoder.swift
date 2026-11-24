import Foundation
import MLX
import MLXLMCommon

// Rows of different length, right-aligned: the mask hides a shorter row's leading padding, positions count its own tokens.
final class BatchAttentionCache: KVCache {
    private(set) var offset: Int
    private var keys: MLXArray
    private var values: MLXArray
    private var padding: [Int]
    private static let step = 256

    private init(keys: MLXArray, values: MLXArray, padding: [Int], offset: Int) {
        self.keys = keys
        self.values = values
        self.padding = padding
        self.offset = offset
    }

    // Each row's keys and values as [1, heads, length, dimension], alike in all but length.
    static func merging(_ rows: [(keys: MLXArray, values: MLXArray)]) throws -> BatchAttentionCache {
        guard let first = rows.first, rows.allSatisfy({ isAlike($0, first) }) else { throw CleanupEngineError.generationFailed() }
        let longest = rows.map { $0.keys.dim(2) }.max() ?? 0
        let padding = rows.map { longest - $0.keys.dim(2) }
        func padded(_ array: MLXArray, by count: Int) -> MLXArray {
            guard count > 0 else { return array }
            var shape = array.shape
            shape[2] = count
            return concatenated([MLXArray.zeros(shape, dtype: array.dtype), array], axis: 2)
        }
        return BatchAttentionCache(
            keys: concatenated(zip(rows, padding).map { padded($0.keys, by: $1) }, axis: 0),
            values: concatenated(zip(rows, padding).map { padded($0.values, by: $1) }, axis: 0),
            padding: padding, offset: longest
        )
    }

    private static func isAlike(_ row: (keys: MLXArray, values: MLXArray), _ first: (keys: MLXArray, values: MLXArray)) -> Bool {
        let (keys, values) = (row.keys.shape, row.values.shape)
        let (firstKeys, firstValues) = (first.keys.shape, first.values.shape)
        return keys.count == 4 && values.count == 4 && keys[0] == 1 && values[0] == 1 && keys[2] == values[2]
            && keys[1] == firstKeys[1] && keys[3] == firstKeys[3] && values[1] == firstValues[1] && values[3] == firstValues[3]
            && row.keys.dtype == first.keys.dtype && row.values.dtype == first.values.dtype
    }

    var ropeOffset: RoPEOffset {
        let positions = padding.map { offset - $0 }
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

    // Columns before a row's own tokens are hidden, as are later tokens and, with a window, ones too far back.
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        guard n > 1 || windowSize != nil || returnArray || padding.contains(where: { $0 > 0 }) else { return .none }
        let columns = MLXArray(Int32(0) ..< Int32(offset + n)).reshaped(1, 1, 1, -1)
        let rows = MLXArray(Int32(offset) ..< Int32(offset + n)).reshaped(1, 1, -1, 1)
        let starts = MLXArray(padding.map(Int32.init)).reshaped(-1, 1, 1, 1)
        var mask = (columns .>= starts) .&& (columns .<= rows)
        if let windowSize { mask = mask .&& (columns .> rows - Int32(windowSize)) }
        return .array(mask)
    }

    var state: [MLXArray] {
        get { [keys[.ellipsis, ..<offset, 0...], values[.ellipsis, ..<offset, 0...]] }
        set {
            guard newValue.count == 2 else { return }
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

    func copy() -> any KVCache {
        BatchAttentionCache(keys: keys[.ellipsis], values: values[.ellipsis], padding: padding, offset: offset)
    }

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

struct BatchReply {
    let tokens: [Int]
    let isCutOff: Bool
}

// Each row reads its prompt alone, as one clean-up does; only the decode steps run batched. A model whose cache this
// cannot merge, or any shape it does not expect, throws, so the caller cleans the rows one by one instead.
struct BatchDecoder {
    let context: ModelContext
    private let stopTokens: Set<Int>

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

    func run(_ prompts: [[Int]], caps: [Int], from kept: InstructionState, prefixLength: Int, parameters: GenerateParameters) throws -> [BatchReply] {
        guard !prompts.isEmpty, caps.count == prompts.count, caps.allSatisfy({ $0 > 0 }) else { throw CleanupEngineError.generationFailed() }
        return try withError { error in
            var (cache, next) = try read(prompts, from: kept, prefixLength: prefixLength, parameters: parameters, error: error)
            var active = Array(prompts.indices)
            var tokens = Array(repeating: [Int](), count: prompts.count)
            var isCutOff = Array(repeating: false, count: prompts.count)
            var steps = 0
            while !active.isEmpty, !Task.isCancelled {
                let current = next
                // The next step is queued before this one's tokens are read, as the single reply's iterator does.
                next = autoreleasepool {
                    let logits = context.model(LMInput.Text(tokens: current[0..., .newAxis]), cache: cache, state: nil).logits
                    let sampled = argMax(logits[0..., -1, 0...], axis: -1)
                    asyncEval([sampled] + cache.flatMap(\.state))
                    return sampled
                }
                try error.check()
                steps += 1
                if steps % 256 == 0 { MLX.Memory.clearCache() }
                let read = current.asArray(Int.self)
                guard read.count == active.count else { throw CleanupEngineError.generationFailed() }
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
                    try keep(kept, in: cache)
                    next = next[MLXArray(kept.map(Int32.init))]
                }
                active = kept.map { active[$0] }
            }
            // A stopped batch still finishes its queued step before its arrays are freed, or Metal trips over them.
            eval(next)
            cache = []
            try Task.checkCancellation()
            return zip(tokens, isCutOff).map { BatchReply(tokens: $0, isCutOff: $1) }
        }
    }

    // Every row's prompt read on its own copy of the instruction, then the rows merged, with each row's first token.
    private func read(
        _ prompts: [[Int]], from kept: InstructionState, prefixLength: Int, parameters: GenerateParameters, error: ErrorBox
    ) throws -> ([any KVCache], MLXArray) {
        let model = context.model
        let instruction = Array(prompts[0].prefix(prefixLength))
        guard prefixLength > 0, Self.merges(kept.cache) else { throw CleanupEngineError.generationFailed() }
        var rowCaches: [[any KVCache]] = []
        var firstTokens: [MLXArray] = []
        for prompt in prompts {
            try Task.checkCancellation()
            guard prompt.count > prefixLength, prompt.starts(with: instruction) else { throw CleanupEngineError.generationFailed() }
            let cache = kept.cache.map { $0.copy() }
            let input = LMInput(tokens: MLXArray(Array(prompt[prefixLength...])))
            let logits = switch try model.prepare(input, cache: cache, state: kept.modelState, prefill: parameters.prefill) {
            case .tokens(let rest): model(rest[text: .newAxis], cache: cache, state: kept.modelState).logits
            case .logits(let output): output.logits
            }
            firstTokens.append(argMax(logits[0..., -1, 0...], axis: -1))
            rowCaches.append(cache)
            try error.check()
        }
        let cache = try merged(rowCaches)
        let first = concatenated(firstTokens)
        eval([first] + cache.flatMap(\.state))
        try error.check()
        return (cache, first)
    }

    // Checked on the instruction before any row is read, so a model this cannot batch costs nothing.
    private static func merges(_ cache: [any KVCache]) -> Bool {
        !cache.isEmpty && cache.allSatisfy { layer in
            if layer is MambaCache { return true }
            return type(of: layer) == KVCacheSimple.self
        }
    }

    private func merged(_ rows: [[any KVCache]]) throws -> [any KVCache] {
        guard let first = rows.first, rows.allSatisfy({ $0.count == first.count }) else { throw CleanupEngineError.generationFailed() }
        return try first.indices.map { layer -> any KVCache in
            if first[layer] is MambaCache {
                let mambas = rows.compactMap { $0[layer] as? MambaCache }
                guard mambas.count == rows.count else { throw CleanupEngineError.generationFailed() }
                let joined = MambaCache()
                for slot in 0 ..< 2 {
                    let parts = mambas.compactMap { $0[slot] }
                    guard parts.count == rows.count else { throw CleanupEngineError.generationFailed() }
                    joined[slot] = concatenated(parts, axis: 0)
                }
                return joined
            }
            return try BatchAttentionCache.merging(rows.map { row in
                let state = row[layer].state
                guard state.count == 2, type(of: row[layer]) == KVCacheSimple.self else { throw CleanupEngineError.generationFailed() }
                return (state[0], state[1])
            })
        }
    }

    private func keep(_ rows: [Int], in cache: [any KVCache]) throws {
        let index = MLXArray(rows.map(Int32.init))
        for layer in cache {
            if let mamba = layer as? MambaCache {
                mamba.filter(batchIndices: index)
            } else if let attention = layer as? BatchAttentionCache {
                attention.keep(rows)
            } else {
                throw CleanupEngineError.generationFailed()
            }
        }
    }
}
