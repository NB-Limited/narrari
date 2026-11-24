import Foundation
import NarrariKit
import Testing

struct PromptStoreTests {
    private let folder = TemporaryFolder()
    private var store: PromptStore { PromptStore(root: folder.url) }
    private let standup = Prompt(id: "standup", name: "Standup", instruction: "Write it as standup notes.", triggers: ["standup notes"])

    @Test func saved_prompts_read_back_after_the_built_ins() throws {
        try store.edit { $0 = [standup] }

        #expect(try store.load() == [standup])
        #expect(try store.all() == PromptStore.builtIn + [standup])
    }

    @Test func missing_file_reads_as_the_built_ins_only() throws {
        #expect(try store.all() == [.tidy, .email, .message, .agentBrief])
    }

    @Test func built_in_prompts_survive_saving_an_empty_list() throws {
        try store.edit { $0 = [standup] }
        try store.edit { $0 = [] }

        #expect(try store.all() == PromptStore.builtIn)
    }
}
