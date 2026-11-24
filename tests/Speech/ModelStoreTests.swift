import Foundation
import NarrariKit
import Testing

struct ModelStoreTests {
    private let folder = TemporaryFolder()

    @Test func a_model_folder_a_download_left_half_written_is_not_on_this_mac_until_its_files_land() throws {
        let store = ModelStore(root: folder.url)
        let weights = store.directory(named: "silero-vad").appending(path: "silero-vad.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: weights.appending(path: "weight.bin.partial"))

        let whileDownloading = store.isPresent(named: "silero-vad")
        try FileManager.default.moveItem(at: weights.appending(path: "weight.bin.partial"), to: weights.appending(path: "weight.bin"))

        #expect(!whileDownloading)
        #expect(store.isPresent(named: "silero-vad"))
    }

    @Test func a_speech_model_missing_a_file_it_loads_is_not_on_this_mac() throws {
        let store = ModelStore(root: folder.url)
        let preprocessor = store.directory(named: ParakeetModel.v3.folder).appending(path: "Preprocessor.mlmodelc")
        try FileManager.default.createDirectory(at: preprocessor, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: preprocessor.appending(path: "coremldata.bin"))

        #expect(!store.isPresent(.v3))
    }
}
