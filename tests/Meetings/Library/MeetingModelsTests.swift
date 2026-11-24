import Foundation
import NarrariKit
import Testing

@MainActor
struct MeetingModelsTests {
    private let folder = TemporaryFolder()

    @Test func a_meeting_model_a_download_left_half_written_is_not_on_this_mac_and_downloads_again() async throws {
        let store = ModelStore(root: folder.url)
        let files = store.directory(named: AudioModel.speakerSplit.folder)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: files.appending(path: "model.bin.partial"))
        let fetch = FakeModelFetch(store: store)
        let models = MeetingModels(store: store, fetch: fetch.fetch)

        let before = models.status(of: .speakerSplit)
        await models.download([AudioModel.speakerSplit])

        #expect(before == .notDownloaded)
        #expect(fetch.fetched.all == [.speakerSplit])
    }
}
