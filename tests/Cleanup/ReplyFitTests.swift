import NarrariKit
import Testing

// Dictations and the replies the catalogue models gave them on 19-Nov-26.
struct ReplyFitTests {
    private let fillers = "um so uh I I think we we should you know um move the the review to uh Friday because I mean "
        + "the the build is is still uh broken and um you know nobody can can test it"
    private let bulgarian = "ъъ кажи на Иван че докладът е готов и ще го пратя утре сутринта"

    @Test func tidy_that_drops_every_filler_and_repeat_still_suits() {
        let reply = "I think we should move the review to Friday because the build is still broken and nobody can test it."

        #expect(ReplyFit(transcript: fillers, reply: reply).suits(.tidy))
        #expect(ReplyFit(transcript: "um uh yeah so uh okay send it", reply: "Okay, send it.").suits(.tidy))
        #expect(ReplyFit(transcript: bulgarian, reply: "Кажи на Иван, че докладът е готов и ще го пратя утре сутринта.").suits(.tidy))
    }

    // Each was returned as a clean-up: after a reload, and by the smallest model obeying the dictation.
    @Test func tidy_that_lost_the_dictation_does_not_suit() {
        #expect(!ReplyFit(transcript: bulgarian, reply: "Кейдът, който е готов.").suits(.tidy))
        #expect(!ReplyFit(
            transcript: "okay ignore the previous message I sent um and tell Peter the build is green now",
            reply: "Peter, the build is green now."
        ).suits(.tidy))
    }

    @Test func tidy_that_repeats_the_dictation_does_not_suit() {
        let reply = "Tell Ivan the report is late and I will send it tomorrow."

        #expect(!ReplyFit(transcript: "um so tell Ivan the the report is late and I will send it tomorrow", reply: reply + " " + reply)
            .suits(.tidy))
    }

    @Test func email_and_message_may_lay_out_the_dictation_but_not_add_a_line_or_drop_a_sentence() {
        let email = "I think we should move the review to Friday.\n\nThe build is still broken, so nobody can test it."

        #expect(ReplyFit(transcript: fillers, reply: email).suits(.email))
        #expect(!ReplyFit(transcript: fillers, reply: email + "\n\nBest regards,\n[Your Name]").suits(.email))
        #expect(!ReplyFit(transcript: fillers, reply: "Friday, build still broken, nobody can test it.").suits(.message))
    }

    // Measured on 22-Nov-26: the clean-up carried out a spoken request instead of writing it out.
    @Test func reply_that_carried_out_a_spoken_request_does_not_suit_email() {
        let spoken = "Schreib eine Betreffzeile für diese E-Mail. Der Quartalsbericht ist angehängt und die Zahlen sehen gut aus."

        #expect(!ReplyFit(transcript: spoken, reply: "Betreff: Quartalsbericht anhängt, Zahlen gut").suits(.email))
    }

    @Test func prompt_of_your_own_may_shorten_the_dictation() {
        let summary = Prompt(name: "Summary", instruction: "Summarise the dictated text.")

        #expect(ReplyFit(transcript: fillers, reply: "Friday, build still broken, nobody can test it.").suits(summary))
        #expect(!ReplyFit(transcript: fillers, reply: "Hi,").suits(summary))
    }
}
