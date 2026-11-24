import NarrariKit
import SwiftUI

// The one play and pause control, in the reader's toolbar and its audio bar.
struct PlayButton: View {
    let playback: AudioPlayback
    // Set when there is nothing to play, and says why.
    var unavailable: String?

    var body: some View {
        let label = playback.isPlaying ? "Pause audio" : "Play audio"
        Button { playback.toggle() } label: {
            Image(systemName: playback.isPlaying ? "pause.circle" : "play.circle")
        }
        .buttonStyle(.icon)
        .disabled(unavailable != nil)
        .accessibilityLabel(label)
        .accessibilityHint(unavailable ?? "")
        .iconLabel(unavailable ?? label, shortcut: unavailable == nil ? "Space" : nil)
    }
}
