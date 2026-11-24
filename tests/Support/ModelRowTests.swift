import NarrariKit
import Testing

struct ModelRowTests {
    @Test func each_state_offers_one_action() {
        let row = { (state: ModelState, isChosen: Bool, bytes: Int64) in ModelRow(state: state, isChosen: isChosen, bytesOnDisk: bytes) }

        #expect(row(.missing, true, 0).action == .download)
        #expect(row(.preparing(fraction: 0.46, isDownloading: true), true, 0).action == .cancel)
        #expect(row(.preparing(fraction: 0.46, isDownloading: true), true, 0).progressLine == "Downloading, 46%")
        #expect(row(.missing, false, 4096).action == nil)
        #expect(row(.ready, true, 4096).action == nil)
        #expect(row(.failed(TranscriberError.modelUnavailable.problem), true, 0).action == .retry)
    }

    @Test func the_radio_is_filled_for_the_chosen_model_and_open_only_for_one_that_can_be_chosen() {
        let row = { (state: ModelState, isChosen: Bool, bytes: Int64) in ModelRow(state: state, isChosen: isChosen, bytesOnDisk: bytes).mark }

        #expect(row(.ready, true, 4096) == .chosen)
        #expect(row(.preparing(fraction: 0.46, isDownloading: true), true, 0) == .chosen)
        #expect(row(.missing, false, 4096) == .available)
        #expect(row(.ready, false, 4096) == .available)
        #expect(row(.missing, true, 4096) == .chosen)
        #expect(row(.missing, true, 0) == .unavailable)
        #expect(row(.preparing(fraction: 0.7, isDownloading: false), false, 4096) == .unavailable)
    }

    @Test func only_files_on_this_mac_can_be_deleted() {
        #expect(ModelRow(state: .ready, isChosen: true, bytesOnDisk: 4096).canDelete)
        #expect(ModelRow(state: .missing, isChosen: false, bytesOnDisk: 4096).canDelete)
        #expect(!ModelRow(state: .missing, isChosen: true, bytesOnDisk: 0).canDelete)
        #expect(!ModelRow(state: .preparing(fraction: 0.2, isDownloading: true), isChosen: true, bytesOnDisk: 0).canDelete)
    }

    @Test func a_model_without_a_pinned_revision_is_offered_for_deletion_only() {
        let row = ModelRow(state: .missing, isChosen: false, bytesOnDisk: 4096, canUse: false)

        #expect(row.action == nil)
        #expect(row.mark == .unavailable)
        #expect(row.canDelete)
        #expect(row.group == .noLongerUsed)
    }

    // Choosing a model already on this Mac must not grow the row or swap its buttons while it loads.
    @Test func a_model_on_this_mac_getting_ready_keeps_its_row() {
        let ready = ModelRow(state: .ready, isChosen: true, bytesOnDisk: 4096)
        let loading = ModelRow(state: .preparing(fraction: 0.3, isDownloading: false), isChosen: true, bytesOnDisk: 4096)

        #expect(loading.isGettingReady)
        #expect(loading.progressLine == nil)
        #expect(loading.action == ready.action)
        #expect(loading.canDelete == ready.canDelete)
        #expect(loading.mark == ready.mark)
        #expect(loading.group == ready.group)
    }

    // Just after a switch the state can still be the previous model's; files on this Mac decide the group.
    @Test func files_on_this_mac_decide_the_group() {
        let row = { (state: ModelState, bytes: Int64) in ModelRow(state: state, isChosen: true, bytesOnDisk: bytes) }

        #expect(row(.ready, 0).group == .toDownload)
        #expect(row(.ready, 0).action == .download)
        #expect(row(.preparing(fraction: 0, isDownloading: false), 0).progressLine == "Downloading, 0%")
        #expect(row(.preparing(fraction: 0, isDownloading: false), 0).group == .toDownload)
        #expect(row(.preparing(fraction: 0.5, isDownloading: true), 4096).group == .toDownload)
        #expect(row(.missing, 4096).group == .onThisMac)
        #expect(row(.failed(TranscriberError.modelUnavailable.problem), 0).group == .toDownload)
    }
}
