import CoreGraphics
import NarrariKit
import Testing

struct AnchoredPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 200, height: 300)

    @Test func opens_below_the_control_lined_up_with_its_leading_edge() {
        let control = CGRect(x: 100, y: 500, width: 180, height: 26)
        let frame = AnchoredPlacement.frame(size: size, anchor: control, gap: 4, alignment: .leading, within: screen)
        #expect(frame == CGRect(x: 100, y: 196, width: 200, height: 300))
    }

    @Test func flips_above_near_the_bottom_of_the_screen() {
        let control = CGRect(x: 100, y: 120, width: 180, height: 26)
        let frame = AnchoredPlacement.frame(size: size, anchor: control, gap: 4, alignment: .leading, within: screen)
        #expect(frame == CGRect(x: 100, y: 150, width: 200, height: 300))
    }

    @Test func shrinks_to_the_larger_side_when_neither_fits() {
        let control = CGRect(x: 100, y: 380, width: 180, height: 26)
        let tall = CGSize(width: 200, height: 600)
        let frame = AnchoredPlacement.frame(size: tall, anchor: control, gap: 4, alignment: .leading, within: screen)
        #expect(frame == CGRect(x: 100, y: 410, width: 200, height: 390))
    }

    @Test func a_label_centred_on_a_button_at_the_right_edge_moves_inside_the_screen() {
        let button = CGRect(x: 980, y: 700, width: 26, height: 26)
        let label = CGSize(width: 140, height: 22)
        let frame = AnchoredPlacement.frame(size: label, anchor: button, gap: 4, alignment: .center, within: screen)
        #expect(frame == CGRect(x: 860, y: 674, width: 140, height: 22))
    }

    @Test func a_list_from_an_icon_button_ends_on_its_trailing_edge() {
        let button = CGRect(x: 600, y: 500, width: 26, height: 26)
        let frame = AnchoredPlacement.frame(size: size, anchor: button, gap: 4, alignment: .trailing, within: screen)
        #expect(frame == CGRect(x: 426, y: 196, width: 200, height: 300))
    }
}
