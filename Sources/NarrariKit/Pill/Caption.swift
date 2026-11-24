import Foundation

public enum Caption {
    public static func words(_ text: String) -> [Substring] {
        words(text[...])
    }

    public static func words(_ text: Substring) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    // Live text covers only the last 14 s of audio; a window's first words may be cut mid-word, so two may be skipped.
    // Only the recent words are searched, so a long dictation merges as fast as a short one.
    public static func merge(_ heard: String, window: String) -> String {
        let recent = lastWords(mergeReach, of: heard, before: 3)
        let earlier = heard[..<recent.startIndex]
        let old = words(recent)
        let new = words(window)
        guard !old.isEmpty, !new.isEmpty else { return window }
        let oldKeys = old.map(matchKey)
        let newKeys = new.map(matchKey)
        var best = (length: 0, at: 0, skip: 0)
        for skip in 0..<min(3, newKeys.count) {
            for at in oldKeys.indices.reversed() {
                var length = 0
                while skip + length < newKeys.count, at + length < oldKeys.count,
                      newKeys[skip + length] == oldKeys[at + length] {
                    length += 1
                }
                if length > best.length { best = (length, at, skip) }
            }
        }
        let needed = min(2, new.count - best.skip)
        guard best.length >= needed, best.length > 0, best.at > best.skip || !earlier.isEmpty else { return window }
        return earlier + (old[..<best.at] + new[best.skip...]).joined(separator: " ")
    }

    static let mergeReach = 100

    // One line of the newest words: as many as it takes to be wider than the line, or all of them.
    public static func lastWords(of text: String, widerThan width: CGFloat, measure: (Substring) -> CGFloat) -> Substring {
        var count = 16
        while true {
            let newest = lastWords(count, of: text, before: 0)
            if newest.startIndex == text.startIndex || measure(newest) > width { return newest }
            count *= 2
        }
    }

    // The last words, or the whole text unless at least `before` more words come ahead of them.
    private static func lastWords(_ count: Int, of text: String, before: Int) -> Substring {
        var start = text.startIndex
        var seen = 0
        var inWord = false
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isWhitespace {
                if inWord {
                    seen += 1
                    if seen == count { start = index }
                    if seen == count + before { return text[start...] }
                }
                inWord = false
            } else {
                inWord = true
            }
            index = previous
        }
        return text[...]
    }

    // Only words past the old text's end are fresh: the recogniser rewords and repunctuates words already shown, and
    // those change in place. Words before the cut are the same in both texts, so only the words after it are counted.
    public static func freshWords(from old: String, to new: String, after cut: CaptionCut = .none) -> Range<Int> {
        let first = cut.words + words(tail(old, after: cut)).count
        return first..<max(first, cut.words + words(tail(new, after: cut)).count)
    }

    private static func matchKey(_ word: Substring) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func textWidth(natural: CGFloat, grown: CGFloat) -> CGFloat {
        let minimum = PillGeometry.captionMinWidth - 2 * PillGeometry.captionPaddingX
        return min(max(natural.rounded(.up), grown, minimum), PillGeometry.captionMeasure)
    }

    public static func visibleLines(_ lines: Int) -> Int {
        min(max(lines, 1), PillGeometry.captionLines)
    }

    public static func plateHeight(lines: Int) -> CGFloat {
        2 * PillGeometry.captionPaddingY + CGFloat(visibleLines(lines)) * PillGeometry.captionLineHeight
    }

    public static func plateRadius(height: CGFloat) -> CGFloat {
        min(PillGeometry.captionRadius, height / 2)
    }

    // The plate is centred, so each edge travels half the growth.
    public static func revealDelay(growth: CGFloat) -> Double {
        let omega = 2 * .pi / PillMotion.captionWidthSpring.duration
        let edge = Double(growth) / 2
        var time = PillMotion.wordDelay
        while time < PillMotion.captionWidthSpring.duration,
              edge * (1 + omega * time) * exp(-omega * time) > Double(PillMotion.fitSlack) {
            time += 1.0 / 240
        }
        return time
    }

    // How far a fresh word has faded in, before easing: words start a stagger apart after the first delay, and from the
    // last stagger step on they start together. Words already shown are in.
    public static func revealProgress(
        _ index: Int, fresh: Range<Int>, firstDelay: Double, elapsed: Double, reduceMotion: Bool
    ) -> Double {
        guard fresh.contains(index) else { return 1 }
        if reduceMotion { return min(1, elapsed / PillMotion.reduced) }
        let start = firstDelay + Double(min(index - fresh.lowerBound, PillMotion.wordStaggerSteps)) * PillMotion.wordStagger
        return min(1, max(0, (elapsed - start) / PillMotion.wordFade))
    }

    // When the last staggered word starts to fade in.
    public static func lastRevealStart(firstDelay: Double) -> Double {
        firstDelay + Double(PillMotion.wordStaggerSteps) * PillMotion.wordStagger
    }

    public static func lineOpacity(line: Int, scrolledTo lastLine: Double) -> Double {
        let above = lastLine - Double(line)
        let leaving = 1 - (above - 1) / PillMotion.scrollFade
        let arriving = (above + 0.6) / 0.3
        return min(1, max(0, min(leaving, arriving)))
    }
}

// The plate lays out only its last lines. SwiftUI wraps the rest of a paragraph the same from any line start it laid
// out, except in a paragraph of two lines or one whose first line holds a word with a hyphen, dash or slash in it.
public struct CaptionCut: Sendable, Equatable {
    public let words: Int
    public let lines: Int
    let offset: Int

    public static let none = CaptionCut(words: 0, lines: 0, offset: 0)
}

extension Caption {
    static let laidOutLines = 4

    public static func tail(_ text: String, after cut: CaptionCut) -> Substring {
        text[text.utf8.index(text.startIndex, offsetBy: cut.offset)...]
    }

    // A cut holds while the text before it is unchanged; otherwise the whole text is laid out again.
    public static func cut(_ cut: CaptionCut, from old: String, to new: String) -> CaptionCut {
        new.utf8.count >= cut.offset && new.utf8.starts(with: old.utf8.prefix(cut.offset)) ? cut : .none
    }

    // Line starts are the word each laid-out line opens with, counted from the start of the text; nil opens mid-word.
    // A layout of other words than the text after the cut is stale and moves nothing.
    public static func lines(_ text: String, at cut: CaptionCut, lineStarts: [Int?], lastWord: Int?) -> Int? {
        guard laysOut(words(tail(text, after: cut)), at: cut, lineStarts: lineStarts, lastWord: lastWord) else { return nil }
        return cut.lines + lineStarts.count
    }

    public static func cut(_ text: String, at cut: CaptionCut, lineStarts: [Int?], lastWord: Int?) -> CaptionCut {
        let shown = tail(text, after: cut)
        let words = words(shown)
        guard laysOut(words, at: cut, lineStarts: lineStarts, lastWord: lastWord) else { return cut }
        // Too few lines left after a shrinking merge: the line scrolling back in would be missing.
        guard lineStarts.count >= laidOutLines - 1 || cut == .none else { return .none }
        for line in stride(from: lineStarts.count - laidOutLines, to: 0, by: -1) {
            guard let start = lineStarts[line], let end = lineStarts[line + 1] else { continue }
            let first = start - cut.words
            let last = end - cut.words
            guard first > 0, first < last, last <= words.count,
                  !words[first..<last].contains(where: { $0.contains(where: breaksInside) }) else { continue }
            let offset = cut.offset + shown.utf8.distance(from: shown.startIndex, to: words[first].startIndex)
            return CaptionCut(words: start, lines: cut.lines + line, offset: offset)
        }
        return cut
    }

    private static func laysOut(_ words: [Substring], at cut: CaptionCut, lineStarts: [Int?], lastWord: Int?) -> Bool {
        lineStarts.first == cut.words && lastWord == cut.words + words.count - 1
    }

    private static func breaksInside(_ character: Character) -> Bool {
        "-\u{2010}\u{2011}\u{2013}\u{2014}/".contains(character)
    }
}

// Halo dims the words before the newest; each settles from the update it stopped being newest in.
public struct CaptionSettle: Sendable, Equatable {
    // The brightness a settled word reaches; 1 settles nothing, as every look but Halo shows it.
    private var settled = 1.0
    private var newest = 0
    private var since: [Int: Double] = [:]
    private var duration = PillMotion.captionSettle

    public init() {}

    // Ages count from this update, `gap` seconds after the last one; words fully settled are dropped.
    public func updated(newest: Int, stopped: [Int], gap: Double, reduceMotion: Bool) -> CaptionSettle {
        var next = CaptionSettle()
        next.duration = reduceMotion ? PillMotion.reduced : PillMotion.captionSettle
        next.since = since.mapValues { $0 + gap }.filter { $0.value < next.duration }
        for index in stopped where index != newest && next.since[index] == nil { next.since[index] = 0 }
        next.since[newest] = nil
        next.settled = PillMotion.captionSettled
        next.newest = newest
        return next
    }

    public func brightness(_ index: Int, after elapsed: Double) -> Double {
        guard settled < 1, index != newest else { return 1 }
        guard let age = since[index].map({ $0 + elapsed }) else { return settled }
        return 1 - (1 - settled) * min(1, max(0, age) / duration)
    }
}
