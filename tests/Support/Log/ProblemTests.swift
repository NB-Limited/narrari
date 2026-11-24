import NarrariKit
import Testing

struct ProblemTests {
    @Test(arguments: [
        ("The meetings could not be read. Try again.", "The meetings could not be read."),
        ("The download failed. Check the connection and try again.", "The download failed. Check the connection."),
        ("Not enough disk space to record. Free some space, then try again.", "Not enough disk space to record. Free some space."),
        ("The model could not load. Try again, or choose another model.", "The model could not load. Try again, or choose another model.")
    ])
    func beside_its_own_try_again_button_a_message_leaves_out_the_words_that_say_the_same(message: String, beside: String) {
        #expect(Problem("test.retry", message, canRetry: true).besideRetry == beside)
        #expect(Problem("test.final", message).besideRetry == message)
    }
}
