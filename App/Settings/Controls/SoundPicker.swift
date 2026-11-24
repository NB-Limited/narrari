import NarrariKit
import SwiftUI

// The app's dropdown, with a play button on each row to hear a set before choosing it.
struct SoundPicker: View {
    let model: RecorderPageModel

    var body: some View {
        Popup(
            label: "Sound",
            selection: Binding(get: { model.soundSet }, set: { model.chooseSound($0) }),
            options: SoundSet.allCases.map { ($0, $0.name) }
        ) { set in
            SoundPlayButton(set: set, isPlaying: model.playingSound == set) { model.previewSound(set) }
        }
    }
}

// A speaker, not a transport control: it plays a short sample and stops by itself. Its waves run while it plays.
struct SoundPlayButton: View {
    let set: SoundSet
    let isPlaying: Bool
    let action: () -> Void
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying && reduceMotion ? "speaker.wave.2.fill" : "speaker.wave.2")
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isPlaying && !reduceMotion)
        }
        .buttonStyle(.icon)
        .accessibilityLabel("Play \(set.name)")
        .iconLabel("Play \(set.name)")
    }
}
