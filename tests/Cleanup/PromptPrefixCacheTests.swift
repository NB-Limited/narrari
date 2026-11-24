import NarrariKit
import Testing

// Stands in for the model's state: the tokens it has read so far.
private final class Reading {
    var tokens: [Int]
    init(_ tokens: [Int]) { self.tokens = tokens }
}

private final class Counts {
    var instructionReads = 0
    var builds = 0
}

struct PromptPrefixCacheTests {
    private let cache = PromptPrefixCache<Reading> { Reading($0.tokens) }
    private let counts = Counts()
    private let tidy = [1, 2, 3]
    private let email = [1, 7, 3]

    private func read(_ prompt: [Int], instruction: [Int]) async -> (prefixLength: Int, state: Reading)? {
        await cache.state(for: prompt) {
            counts.instructionReads += 1
            return instruction
        } build: { tokens in
            counts.builds += 1
            return Reading(tokens)
        }
    }

    @Test func instruction_is_read_once_for_dictations_with_the_same_prompt() async throws {
        let first = try #require(await read(tidy + [10], instruction: tidy))
        let second = try #require(await read(tidy + [20, 21], instruction: tidy))

        #expect(first.prefixLength == 3)
        #expect(second.prefixLength == 3)
        #expect(second.state.tokens == tidy)
        #expect(counts.instructionReads == 1)
        #expect(counts.builds == 1)
    }

    @Test func changed_prompt_reads_its_instruction_again() async throws {
        _ = await read(tidy + [10], instruction: tidy)
        let changed = try #require(await read(email + [10], instruction: email))

        #expect(changed.state.tokens == email)
        #expect(counts.builds == 2)
    }

    @Test func dictated_words_never_reach_the_kept_instruction() async throws {
        let first = try #require(await read(tidy + [10], instruction: tidy))
        first.state.tokens += [10]

        let second = try #require(await read(tidy + [20], instruction: tidy))

        #expect(second.state.tokens == tidy)
    }

    @Test func prompt_that_does_not_start_with_its_instruction_is_read_whole() async {
        #expect(await read([9] + tidy + [10], instruction: tidy) == nil)
        #expect(await read(tidy, instruction: tidy) == nil)
        #expect(counts.builds == 0)
    }
}
