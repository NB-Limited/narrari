import NarrariKit
import SwiftUI

extension EnvironmentValues {
    // Set on every hosted root by followsMotion(_:); a view reads this, never the system setting.
    @Entry var reducesMotion = false
}

private struct FollowsMotion: ViewModifier {
    let motion: ReduceMotion

    func body(content: Content) -> some View {
        content.environment(\.reducesMotion, motion.isOn)
    }
}

extension View {
    func followsMotion(_ motion: ReduceMotion) -> some View {
        modifier(FollowsMotion(motion: motion))
    }
}
