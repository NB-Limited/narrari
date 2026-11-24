import AppKit
import NarrariKit
import SwiftUI

extension Color {
    static let windowGround = Color("Window")
    static let surface = Color("Surface")
    static let sidebarGround = Color("Sidebar")
    static let selectionFill = Color("Selection")
    static let pressedFill = Color("Pressed")
    static let ink = Color("Ink")
    static let ink2 = Color("Ink2")
    static let muted = Color("Muted")
    static let rule = Color("Rule")
    static let controlEdge = Color("ControlEdge")
    static let errorInk = Color("Error")
    static let onInk = Color("OnInk")
    static let switchOn = Color("SwitchOn")

    static let pillFill = Color("PillFill")
    static let pillText = Color("PillText")
    static let pillMuted = Color("PillMuted")
    static let pillError = Color("PillError")
    static let pillBlack = Color("PillBlack")
    static let pillClean = Color("PillClean")
    static let pillDone = Color("PillDone")
    static let pillRecord = Color("PillRecord")

    static let panelGround = Color("PanelGround")
    static let panelMuted = Color("PanelMuted")
    static let panelEdge = Color("PanelEdge")
    static let panelInnerEdge = Color("PanelInnerEdge")
    static let panelHover = Color("PanelHover")
    static let panelRule = Color("PanelRule")
    static let panelTrack = Color("PanelTrack")
    static let keycap = Color("Keycap")
    static let keycapText = Color("KeycapText")
    static let keycapEdge = Color("KeycapEdge")
    static let keycapShadow = Color("KeycapShadow")
    static let cardEdge = Color("CardEdge")
    static let cardShadow = Color("CardShadow")
    static let cardButton = Color("CardButton")
}

@MainActor
enum Typeface {
    static let pillFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let pill = Font(pillFont)
    static let pillTimerFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let pillTimer = Font(pillTimerFont)
    static let pillBaselineBelowCenter = (pillFont.capHeight / 2).rounded()
    static let captionFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let caption = Font(captionFont)
    static let captionSpace = (" " as NSString).size(withAttributes: [.font: captionFont]).width
    // SwiftUI sets SF on AppKit's line height (15 at 12 pt), not on ascender plus descender (14.1).
    static let captionGlyphBox = NSLayoutManager().defaultLineHeight(for: captionFont)
    static let captionLineSpacing = max(0, PillGeometry.captionLineHeight - captionGlyphBox)
    // Half the line spacing goes above the first line, as a CSS line height does, so one line sits centred on the plate.
    static let captionTop = PillGeometry.captionPaddingY + captionLineSpacing / 2
    static let heardFont = serif(size: 15, weight: 400, opticalSize: 15)
    static let heard = Font(heardFont)
    static let heardLineSpacing = lineSpacing(heardFont, lineHeight: 1.55)
    static let cardLineSpacing = lineSpacing(heardFont, lineHeight: 1.5)
    static let cardLineBox = heardFont.ascender - heardFont.descender + heardFont.leading

    static let saidFont = serif(size: 20, weight: 400, opticalSize: 20)
    static let said = Font(saidFont)
    static let saidLineSpacing = lineSpacing(saidFont, lineHeight: 1.5)
    static let saidTracking: CGFloat = -0.003 * 20

    static let titleFont = serif(size: 28, weight: 500, opticalSize: 40)
    static let title = Font(titleFont)
    static let titleLineSpacing = lineSpacing(titleFont, lineHeight: 1.2)

    static let wordmarkSize: CGFloat = 56
    static let wordmark = Font(serif(size: wordmarkSize, weight: 500, opticalSize: 60))
    static let wordmarkTracking: CGFloat = 0.16 * wordmarkSize

    static let label = Font.system(size: 11, weight: .semibold)
    static let meta = Font.system(size: 11)
    static let small = Font.system(size: 12)
    static let smallStrong = Font.system(size: 12, weight: .semibold)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let labelMediumFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let labelMedium = Font(labelMediumFont)
    static let cardMeta = Font.system(size: 11.5).monospacedDigit()
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let body = Font(bodyFont)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let bodyLineSpacing = lineSpacing(bodyFont, lineHeight: 1.38)
    static let listLineSpacing = lineSpacing(bodyFont, lineHeight: 1.35)
    static let button = Font.system(size: 13)
    static let primaryButton = Font.system(size: 13, weight: .medium)
    static let position = Font.system(size: 12, design: .monospaced).monospacedDigit()
    static let groupTracking: CGFloat = 0.02 * 11

    // CSS line heights become the extra space SwiftUI adds between lines.
    private static func lineSpacing(_ font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, font.pointSize * lineHeight - (font.ascender - font.descender + font.leading))
    }

    // Axis keys are the four-character tags read as big-endian integers.
    private static let weightAxis = 0x7767_6874
    private static let opticalSizeAxis = 0x6F70_737A

    private static func serif(size: CGFloat, weight: CGFloat, opticalSize: CGFloat) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: "SourceSerif4Variable-Roman",
            .variation: [weightAxis: weight, opticalSizeAxis: opticalSize]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
    }
}

enum Symbol {
    static let window: CGFloat = 14
    static let permission: CGFloat = 16
    static let note: CGFloat = 12
    static let disclosure: CGFloat = 9
}

enum Radius {
    static let control: CGFloat = 6
    static let listItem: CGFloat = 7
    static let window: CGFloat = 12
    static let bar: CGFloat = 2
}

enum Space {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s14: CGFloat = 14
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s22: CGFloat = 22
    static let s36: CGFloat = 36
}

enum ControlMetrics {
    static let buttonHeight: CGFloat = 24
    static let buttonPadding: CGFloat = 11
    static let fieldHeight: CGFloat = 26
    static let iconButton: CGFloat = 26
    static let edge: CGFloat = 1
    static let hairline: CGFloat = 0.5
    static let errorEdge: CGFloat = 1.5
    static let errorGap: CGFloat = 5
    static let innerGap: CGFloat = 6
    static let popupLeading: CGFloat = 9
    static let disabledOpacity = 0.45
    static let pressedOpacity = 0.7
    static let navRowHeight: CGFloat = 28
    static let switchHeight: CGFloat = 19
    static let progressHeight: CGFloat = 4
    static let radio: CGFloat = 15
    static let swatch: CGFloat = 18
    static let swatchGap: CGFloat = 8
    static let swatchCheck: CGFloat = 10
    static let radioOnEdge: CGFloat = 4.5
    static let focusRing: CGFloat = 2
    static let focusOffset: CGFloat = 3
    static let textAreaHeight: CGFloat = 112
    static let appIcon: CGFloat = 16
}

enum ListMetrics {
    static let pickerSize = CGSize(width: 300, height: 340)
}

enum WindowMetrics {
    static let minimumSize = CGSize(width: 640, height: 400)
    static let defaultSize = CGSize(width: 820, height: 560)
    static let sidebarWidth: CGFloat = 236
    static let itemPadding: CGFloat = 7
    static let itemGap: CGFloat = 1
    static let trafficLightRow: CGFloat = 40
    static let toolbarHeight: CGFloat = 46
    static let trackHeight: CGFloat = 4
    static let knob: CGFloat = 10
    static let aboutWidth: CGFloat = 400
    static let dropLine: CGFloat = 1.5
}

// The card drop, shared by the menu panel's card and the raised plates in settings.
enum Shadow {
    static let card = (radius: CGFloat(1), y: CGFloat(1))
}

enum Motion {
    static let labelDelay: Duration = .milliseconds(400)
    static let copiedHold: Duration = .milliseconds(1500)
    // A model that loads quicker than this changes nothing on screen.
    static let slowLoad: Duration = .milliseconds(400)
    static let loadTurn = 1.0
    static let loadArc = 0.3
    static let loadTrack = 0.2
    static let fade = Animation.easeOut(duration: 0.2)

    // DESIGN's two curves, enter and exit, and the caption's lift, each in the three forms the views animate with.
    struct Curve {
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double

        static let enter = Curve(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
        static let exit = Curve(x1: 0.4, y1: 0, x2: 1, y2: 1)
        static let lift = Curve(x1: 0.3, y1: 0, x2: 0.2, y2: 1)

        func animation(duration: Double) -> Animation {
            .timingCurve(x1, y1, x2, y2, duration: duration)
        }

        var timingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        }

        var unitCurve: UnitCurve {
            .bezier(startControlPoint: UnitPoint(x: x1, y: y1), endControlPoint: UnitPoint(x: x2, y: y2))
        }
    }
}

// The in-app dropdown list and the label an icon button shows on hover, both floating panels over the window.
enum FloatingMetrics {
    static let radius: CGFloat = 10
    static let edge: CGFloat = 1
    static let gap: CGFloat = 4
    static let listInset: CGFloat = 4
    static let rowHeight: CGFloat = 24
    static let rowPadding: CGFloat = 6
    static let checkColumn: CGFloat = 14
    static let checkGap: CGFloat = 6
    static let titleReach = listInset + rowPadding + checkColumn + checkGap - ControlMetrics.popupLeading
    static let maxRows = 10
    static let maxListWidth: CGFloat = 360
    static let groupHeight: CGFloat = 27
    static let groupIndent: CGFloat = 26 - listInset
    static let sectionHeight: CGFloat = 9
    static let fieldHeight: CGFloat = 30
    static let labelRadius: CGFloat = 6
    static let labelHeight: CGFloat = 22
    static let labelPadding: CGFloat = 8
    static let labelShortcutGap: CGFloat = 6
}

// Pill sizes and timings live in NarrariKit's PillGeometry and PillMotion.
enum PillMetrics {
    static let check: CGFloat = 13
    static let plateSymbol: CGFloat = 12
    static let plateSymbolGap: CGFloat = 6
    static let screenMargin: CGFloat = 18
    static let glassSpacing: CGFloat = 4
    static let capsuleTint = 0.78
    static let plateTint = 0.72
    // Smoked: a PillFill layer inside the glass; Liquid Glass tint alone does not darken it.
    static let capsuleSmoke = 0.88
    static let plateSmoke = 0.85
    static let solidEdge = Color.white.opacity(0.12)
    // Clear: a lighter tint, the page showing through above and below the content; the smoke is dense only where the content sits.
    static let clearTint = 0.30
    static let clearSmoke = [(0.0, 0.06), (0.22, 0.52), (0.36, 0.86), (0.64, 0.86), (0.78, 0.52), (1.0, 0.10)]
    static let clearPlateSmoke = 0.80
    static let clearRimWidth: CGFloat = 1
    static let clearRim = [(0.0, 0.60), (0.5, 0.14), (1.0, 0.34)]
    static let glossSheen = [(0.0, 0.14), (0.5, 0.0)]
    static let glossEdgeWidth: CGFloat = 1
    static let glossEdge = [(0.0, 0.45), (0.5, 0.12), (1.0, 0.20)]
    static let rimWidth: CGFloat = 0.5
    static let rim = [(0.0, 0.30), (0.45, 0.13), (1.0, 0.10)]
    static let contrastInnerEdge = Color.white.opacity(0.5)
    static let contrastOuterEdge = Color.black.opacity(0.7)
    static let contrastEdgeWidth: CGFloat = 1
    static let capsuleShadow = (opacity: 0.22, radius: 9.0, y: 6.0, contact: 0.16)
    static let plateShadow = (opacity: 0.14, radius: 8.0, y: 4.0, contact: 0.10)
    static let captionEdgeInset: CGFloat = 4
    static let captionEdgeFeather: CGFloat = 6
    static let captionTopFeather: CGFloat = 6
    static let inlineFeather: CGFloat = 16
    // Halo: the line's brightness in silence, the outline's while working with Reduce Motion, and its glow inside the glass.
    static let haloQuiet = 0.55
    static let haloSteady = 0.4
    static let haloGlow = [(width: 7.0, opacity: 0.06), (width: 4.0, opacity: 0.16)]
}

// The meeting pill, the corner chip and the call notice; their surface and type are the pill's.
enum MeetingMetrics {
    static let dot: CGFloat = 8
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 5
    static let dividerHeight: CGFloat = 16
    static let dividerOpacity = 0.22
    static let dividerBefore: CGFloat = 10
    static let dividerAfter: CGFloat = 6
    static let button: CGFloat = 26
    static let buttonPadding: CGFloat = 12
    static let iconButtonSymbol: CGFloat = 13
    static let hoverWash = 0.14
    static let pressedWash = 0.22
    static let outlineEdge = 0.45
    static let pressedOpacity = 0.8
    static let foldGap: CGFloat = 6
    static let foldReach = PillGeometry.doneDiameter + foldGap
    static let chipGap: CGFloat = 8
    static let chipSymbol: CGFloat = 13
    static let cornerBelowMenuBar: CGFloat = 8
    static let cornerFromEdge: CGFloat = 12
    static let noticeWidth: CGFloat = 340
    static let noticeRadius: CGFloat = 16
    static let noticePadding = EdgeInsets(top: 8, leading: 14, bottom: 10, trailing: 8)
    static let noticeGap: CGFloat = 8
    static let noticeIcon: CGFloat = 16
    static let noticeLine: CGFloat = 18
    static let noticeTitleTop: CGFloat = 2
    static let noticeTitleTrailing: CGFloat = 6
    static let noticeTitleLines = 2
    static let dismissSymbol: CGFloat = 12
    static let dismissWash = 0.12
    // Twice a second, so the shown second never lags the recorder by most of one.
    static let timerTick = 0.5
    static let noticeEnter = 0.16
    static let noticeLeave = 0.2
    static let noticeSpring = (duration: 0.4, bounce: 0.1)
    static let noticeScale = 0.92
}

// The Recorder look preview in General: a light and a dark page side by side, the pill at true size on each.
enum MeetingWindowMetrics {
    static let pinMark: CGFloat = 10
    static let stateTop: CGFloat = 3
    static let switchSegment: CGFloat = 102
    static let tabSegment: CGFloat = 110
    static let titleTop: CGFloat = 10
    static let peopleTop: CGFloat = 6
    static let attentionTop: CGFloat = 10
    static let noteGap: CGFloat = 5
    static let stepsTop: CGFloat = 12
    static let tabsTop: CGFloat = 16
    static let contentTop: CGFloat = 14
    static let turnGap: CGFloat = 12
    static let speakerLineGap: CGFloat = 8
    static let chipHeight: CGFloat = 22
    static let chipPadding: CGFloat = 6
    static let lineTop: CGFloat = 1
    static let lineHover: CGFloat = 3
    // Scrolled this close to the end still counts as at the end, so live text follows.
    static let endSlack: CGFloat = 24
    static let stepSymbol: CGFloat = 16
    static let stepName: CGFloat = 104
    static let stepRow: CGFloat = 26
    static let stepBar = CGSize(width: 96, height: 4)
    static let notesHead: CGFloat = 24
    static let notesTop: CGFloat = 24
    static let notesMinHeight: CGFloat = 48
    static let notesPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let headingTop: CGFloat = 12
    static let listIndent: CGFloat = 18
    static let detailKey: CGFloat = 92
    static let recordingDot: CGFloat = 7
    static let appIcon: CGFloat = 14
    static let appIconRadius: CGFloat = 3.5
    static let speakerDetailTop: CGFloat = 2
    static let quietTop: CGFloat = 12
    static let emptyActionsTop: CGFloat = 20
}

enum PillPreviewMetrics {
    static let top: CGFloat = 10
    static let gap: CGFloat = 12
    static let height: CGFloat = 112
    static let bottom: CGFloat = 16
    static let radius: CGFloat = 8
    static let lightPage = Color.white
    static let darkPage = Color(red: 0x1C / 255, green: 0x1D / 255, blue: 0x21 / 255)
    static let lightLine = Color(red: 0xDD / 255, green: 0xE0 / 255, blue: 0xE4 / 255)
    static let darkLine = Color(red: 0x34 / 255, green: 0x37 / 255, blue: 0x3E / 255)
    static let lines: [CGFloat] = [0.86, 0.72, 0.9, 0.64]
    static let lineHeight: CGFloat = 5
    static let lineGap: CGFloat = 9
    static let linePadding: CGFloat = 16
}

// The menu bar panel, from the Glance card prototype.
enum MenuPanelMetrics {
    static let recordingDot: CGFloat = 4
    static let problemMark: CGFloat = 7
    static let problemMarkGap: CGFloat = 1
    static let width: CGFloat = 304
    static let inset: CGFloat = 6
    static let radius: CGFloat = 14
    static let belowMenuBar: CGFloat = 4
    static let leadingOffset: CGFloat = 8
    static let screenMargin: CGFloat = 8

    static let statusPadding = EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8)
    static let statusGap: CGFloat = 7
    static let warningGap: CGFloat = 6
    static let warningSymbol: CGFloat = 13
    static let elapsedOpacity = 0.7
    static let hintGap: CGFloat = 5
    static let keycapHeight: CGFloat = 18
    static let keycapPadding: CGFloat = 6
    static let keycapRadius: CGFloat = 4
    static let keycapDrop: CGFloat = 1
    static let progressPadding = EdgeInsets(top: 0, leading: 8, bottom: 8, trailing: 8)
    static let fixRowPadding = EdgeInsets(top: -2, leading: 0, bottom: 6, trailing: 0)

    static let cardRadius: CGFloat = 10
    static let cardPadding = EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14)
    static let cardLines = 4
    static let cardFade: CGFloat = 56
    static let cardRing: CGFloat = 2
    static let cardPressedScale = 0.985
    static let footerGap: CGFloat = 9
    static let copyHeight: CGFloat = 24
    static let copyPadding = EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 8)
    static let copyRadius: CGFloat = 6
    static let copyGap: CGFloat = 6
    static let copySymbol: CGFloat = 13
    static let returnOpacity = 0.6

    static let modeTop: CGFloat = 6
    static let modeHeight: CGFloat = 30
    static let modeValueGap: CGFloat = 4
    static let modeSymbol: CGFloat = 12
    static let modeListPadding = EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0)
    static let checkInset: CGFloat = 2
    static let checkColumn: CGFloat = 18
    static let checkSymbol: CGFloat = 12

    static let rowHeight: CGFloat = 26
    static let rowPadding: CGFloat = 8
    static let rowRadius: CGFloat = 7
    static let rowGap: CGFloat = 8
    static let shortcutOpacity = 0.6
    static let disabledOpacity = 0.4
    static let pressedMultiply = 0.92
    static let separatorPadding = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)

    static let openDuration = 0.2
    static let openRise: CGFloat = 4
    static let closeDuration = 0.15
    static let keyPress: Duration = .milliseconds(90)
    static let copiedHold: Duration = .milliseconds(300)
}

// The settings grid and model list, from the settings pass 2 prototype.
extension Color {
    static let tagEdge = Color("TagEdge")
    // The chosen segment, lighter than its track in both themes.
    static let raised = Color("Raised")
    // The model in use; darker than Raised in dark so Muted text and the meter track still read on it.
    static let chosenPlate = Color("ChosenPlate")
    static let raisedEdge = Color("RaisedEdge")
    static let meterTrack = Color("MeterTrack")
}

enum SettingsGrid {
    static let formWidth: CGFloat = 480
    static let titleTop: CGFloat = 2
    static let titleBottom: CGFloat = 4
    static let groupHeight: CGFloat = 24
    static let groupTop: CGFloat = 32
    static let groupBottom: CGFloat = 2
    static let rowPadding: CGFloat = 9
    static let rowMinHeight: CGFloat = 44
    static let rowGap: CGFloat = 12
    static let nameLine: CGFloat = 18
    static let detailLine: CGFloat = 16
    static let detailGap: CGFloat = 2
    static let controlWidth: CGFloat = 180
    static let controlGap: CGFloat = 8
    static let edgeIconPull: CGFloat = 6
    static let firstFieldTop: CGFloat = 2
    static let listTop: CGFloat = 12
    static let editorBottom: CGFloat = 12
    static let blockGap: CGFloat = 16
    static let subRowPadding: CGFloat = 4
    static let appIndent: CGFloat = 24
    static let orderColumn: CGFloat = 10
    static let warning: CGFloat = 12

    static let modelLead: CGFloat = 18
    static let modelGap: CGFloat = 10
    static let actionWidth: CGFloat = 88
    static let helperGap: CGFloat = 4
    static let plateOutset: CGFloat = 8
    static let plateInset: CGFloat = 5
    static let promptTextPadding = EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    static let tagGap: CGFloat = 6
    static let summaryTop: CGFloat = 1
    static let progressTop: CGFloat = 6
    static let progressBottom: CGFloat = 2
    static let editorIndent: CGFloat = modelLead + modelGap

    static let tagHeight: CGFloat = 16
    static let tagPadding: CGFloat = 5
    static let tagRadius: CGFloat = 4

    static let metricsTop: CGFloat = 10
    static let metricCell: CGFloat = 88
    static let metricGap: CGFloat = 6
    static let metricBarTop: CGFloat = 6
    static let metricStep: CGFloat = 3
    static let metricStepGap: CGFloat = 2
    static let metricColumnGap: CGFloat = 20
    static let metricRowGap: CGFloat = 10

    static let subheadTop: CGFloat = 16
    static let subheadBottom: CGFloat = 2
    static let chosenEdge: CGFloat = 1

    static let segmentWidth: CGFloat = 140
    static let segmentHeight: CGFloat = 28
    static let segmentInset: CGFloat = 2
    static let segmentRadius: CGFloat = 7
    static let segmentMark: CGFloat = 5

    static let legendTop: CGFloat = 10
    static let legendWord: CGFloat = 34
    static let legendSequence: CGFloat = 150
    static let legendRowGap: CGFloat = 8
    static let legendColumnGap: CGFloat = 12
    static let legendGap: CGFloat = 6
    static let heldBar = CGSize(width: 54, height: 4)
    static let tapDot: CGFloat = 3
    static let tapDotGap: CGFloat = 4
}
