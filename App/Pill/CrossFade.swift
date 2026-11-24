import SwiftUI

struct FadeTiming {
    let out: Animation
    let `in`: Animation
    let leading: Bool
    let blur: CGFloat
}

// Transitions take the transaction's animation, which would let old content outlive a shrinking shape; two faces fade on their own clocks.
struct CrossFade<Value: Equatable, Content: View>: View {
    let value: Value
    let timing: FadeTiming
    @ViewBuilder let content: (Value, _ leading: Bool) -> Content

    @State private var faces: [Value?]
    @State private var leading = [false, false]
    @State private var firstShown = true
    @State private var secondShown = false
    @State private var active = 0

    init(value: Value, timing: FadeTiming, @ViewBuilder content: @escaping (Value, Bool) -> Content) {
        self.value = value
        self.timing = timing
        self.content = content
        _faces = State(initialValue: [value, nil])
    }

    var body: some View {
        ZStack {
            face(0, shown: firstShown)
            face(1, shown: secondShown)
        }
        .onChange(of: value) { _, new in swap(to: new) }
    }

    private func face(_ index: Int, shown: Bool) -> some View {
        ZStack {
            if let value = faces[index] { content(value, leading[index]) }
        }
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : timing.blur)
    }

    private func swap(to new: Value) {
        let old = active
        let next = 1 - old
        active = next
        withAnimation(timing.out) {
            setShown(old, false)
        } completion: {
            if active != old { faces[old] = nil }
        }
        leading[next] = timing.leading
        withAnimation(timing.in) {
            faces[next] = new
            setShown(next, true)
        }
    }

    private func setShown(_ index: Int, _ shown: Bool) {
        if index == 0 { firstShown = shown } else { secondShown = shown }
    }
}

struct TrailingFade: View {
    let feather: CGFloat
    let clearance: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: feather)
            Color.clear.frame(width: clearance)
        }
    }
}
