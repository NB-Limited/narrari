import Foundation

// Keeps the model's state after the instruction part of a prompt, so a dictation with the same instruction is the
// only new work. It holds the instruction alone and hands out copies, so no dictated words ever reach what it keeps.
public final class PromptPrefixCache<State> {
    private var kept: (tokens: [Int], state: State)?
    private let copy: (State) -> State

    public init(copy: @escaping (State) -> State) {
        self.copy = copy
    }

    // Nil when the prompt does not start with its instruction tokens; the caller then reads the whole prompt.
    public func state(
        for prompt: [Int],
        instruction: () async throws -> [Int],
        build: ([Int]) throws -> State
    ) async rethrows -> (prefixLength: Int, state: State)? {
        if let kept, Self.extends(prompt, kept.tokens) { return (kept.tokens.count, copy(kept.state)) }
        let tokens = try await instruction()
        guard Self.extends(prompt, tokens) else { return nil }
        let state = try build(tokens)
        kept = (tokens, state)
        return (tokens.count, copy(state))
    }

    private static func extends(_ prompt: [Int], _ prefix: [Int]) -> Bool {
        !prefix.isEmpty && prompt.count > prefix.count && prompt.starts(with: prefix)
    }
}
