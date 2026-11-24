import NarrariKit
import Testing

struct TriggerMatcherTests {
    private let reply = Prompt(id: "reply", name: "Reply", instruction: "Write a reply.", triggers: ["reply"])
    private let replyAll = Prompt(id: "reply-all", name: "Reply all", instruction: "Write a reply to all.", triggers: ["reply to all"])

    @Test func trigger_counts_only_at_the_start() {
        let match = TriggerMatcher.match("Please write email to Anna", prompts: [.email])

        #expect(match.prompt == nil)
        #expect(match.text == "Please write email to Anna")
    }

    @Test func longest_trigger_wins() {
        let match = TriggerMatcher.match("Reply to all, we ship on Friday", prompts: [reply, replyAll])

        #expect(match.prompt == replyAll)
        #expect(match.text == "We ship on Friday")
    }

    @Test(arguments: zip(
        ["write email: hi anna, see you", "Write email - hi Anna", "write email.", "write emailing anna"],
        ["hi anna, see you", "Hi Anna", "", "write emailing anna"]
    ))
    func trigger_is_removed_with_its_separator(transcript: String, text: String) {
        #expect(TriggerMatcher.match(transcript, prompts: [.email]).text == text)
    }

    @Test func case_and_punctuation_are_ignored() {
        let match = TriggerMatcher.match("WRITE, EMAIL! thanks for the call", prompts: [.email])

        #expect(match.prompt == .email)
        #expect(match.text == "Thanks for the call")
    }
}
