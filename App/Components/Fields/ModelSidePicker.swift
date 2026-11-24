import NarrariKit
import SwiftUI

// On this Mac or the outside service; the side that holds the model in use keeps its mark from the other side.
struct ModelSidePicker: View {
    @Binding var side: ModelSide
    let inUse: ModelSide?

    var body: some View {
        SegmentedControl(
            label: "Where the model runs",
            selection: $side,
            segments: [(.thisMac, "On this Mac"), (.outside, "Outside service")],
            marked: inUse,
            markLabel: "Model in use"
        )
        .padding(.top, Space.s4)
    }
}
