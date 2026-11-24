import Foundation
import NarrariKit

struct PieceSetting: Hashable {
    static let sweep = [0.3, 0.5, 0.8].flatMap { pause in [5.0, 10.0].map { PieceSetting(pause: pause, minimum: $0) } }

    let pause: Double
    let minimum: Double
    var label: String { String(format: "pause %.1f min %02.0f", pause, minimum) }
}

struct PieceCut: Equatable {
    // The sample the next piece starts at, and the sample the recorder had heard when it chose the cut.
    let at: Int
    let decidedAt: Int
    let forced: Bool
}

// Causal: a cut chosen at a frame sees only frames up to it. The gate's floor and ratio are FluidAudio 0.18.3's own pause cut.
struct PauseCutter {
    static let frame = 320
    static let floorRMS: Float = 0.004
    static let gateRatio: Float = 0.18
    static let longest = 14.0
    static let forcedLookback = 3.0
    static let quietestFrames = 5

    let setting: PieceSetting

    func cuts(_ samples: [Float]) -> [PieceCut] {
        let rate = SpeechAudio.sampleRate
        let pauseFrames = Int((setting.pause * rate / Double(Self.frame)).rounded(.up))
        let half = Int(setting.pause * rate / 2)
        var levels: [Float] = []
        var peak: Float = 0
        var quiet = 0
        var start = 0
        var cuts: [PieceCut] = []
        for index in 0..<(samples.count / Self.frame) {
            let level = Self.rms(samples[(index * Self.frame)..<((index + 1) * Self.frame)])
            levels.append(level)
            peak = max(peak, level)
            quiet = level <= max(Self.floorRMS, Self.gateRatio * peak) ? quiet + 1 : 0
            let now = (index + 1) * Self.frame
            if quiet >= pauseFrames, Double(now - half - start) >= setting.minimum * rate {
                cuts.append(PieceCut(at: now - half, decidedAt: now, forced: false))
                start = now - half
            } else if Double(now - start) >= Self.longest * rate {
                let at = Self.quietest(levels, after: now - Int(Self.forcedLookback * rate))
                cuts.append(PieceCut(at: at, decidedAt: now, forced: true))
                start = at
            }
        }
        return cuts
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    // The middle of the quietest 100 ms after the given sample.
    static func quietest(_ levels: [Float], after sample: Int) -> Int {
        let first = max(0, sample / frame)
        let last = levels.count - quietestFrames
        guard last > first else { return levels.count * frame }
        let best = (first...last).min { lhs, rhs in
            levels[lhs..<(lhs + quietestFrames)].reduce(0, +) < levels[rhs..<(rhs + quietestFrames)].reduce(0, +)
        } ?? first
        return (best * frame) + quietestFrames * frame / 2
    }
}

// The words of a transcript, lowercased without punctuation, each with the spaced token it came from.
struct TranscriptWords {
    let words: [String]
    let tokens: [Substring]
    let tokenOf: [Int]
    let isTokenEnd: [Bool]

    init(_ text: String) {
        var words: [String] = []
        var tokenOf: [Int] = []
        var isTokenEnd: [Bool] = []
        let tokens = text.split(whereSeparator: \.isWhitespace)
        for (index, token) in tokens.enumerated() {
            let parts = normalizedWords(String(token))
            words += parts
            tokenOf += Array(repeating: index, count: parts.count)
            isTokenEnd += parts.indices.map { $0 == parts.count - 1 }
        }
        self.words = words
        self.tokens = tokens
        self.tokenOf = tokenOf
        self.isTokenEnd = isTokenEnd
    }

    static func endsSentence(_ text: some StringProtocol) -> Bool {
        text.last.map { ".?!".contains($0) } ?? false
    }

    func endsSentence(at word: Int) -> Bool {
        isTokenEnd[word] && Self.endsSentence(tokens[tokenOf[word]])
    }

    func startsCapital(at word: Int) -> Bool {
        tokens[tokenOf[word]].first?.isUppercase ?? false
    }
}

// A minimum edit path between two word lists: each step pairs a word of each, or a word of one with none.
struct WordAlignment {
    struct Hunk {
        let left: Range<Int>
        let right: Range<Int>
        var weight: Int { max(left.count, right.count) }
    }

    let steps: [(left: Int?, right: Int?)]
    let errors: Int

    init(_ left: [String], _ right: [String]) {
        let width = right.count + 1
        var cost = [Int](repeating: 0, count: (left.count + 1) * width)
        for j in 0...right.count { cost[j] = j }
        for i in 1..<(left.count + 1) {
            cost[i * width] = i
            for j in 1..<width {
                let same = left[i - 1] == right[j - 1] ? 0 : 1
                cost[i * width + j] = min(cost[(i - 1) * width + j - 1] + same, cost[(i - 1) * width + j] + 1, cost[i * width + j - 1] + 1)
            }
        }
        var steps: [(left: Int?, right: Int?)] = []
        var (i, j) = (left.count, right.count)
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i * width + j] == cost[(i - 1) * width + j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1) {
                steps.append((i - 1, j - 1))
                (i, j) = (i - 1, j - 1)
            } else if i > 0, cost[i * width + j] == cost[(i - 1) * width + j] + 1 {
                steps.append((i - 1, nil))
                i -= 1
            } else {
                steps.append((nil, j - 1))
                j -= 1
            }
        }
        self.steps = steps.reversed()
        errors = cost[left.count * width + right.count]
    }

    func hunks(_ left: [String], _ right: [String]) -> [Hunk] {
        var hunks: [Hunk] = []
        var open: (left: Int, right: Int)?
        var cursor = (left: 0, right: 0)
        for step in steps {
            let isSame = step.left.flatMap { l in step.right.map { left[l] == right[$0] } } ?? false
            if isSame, let start = open {
                hunks.append(Hunk(left: start.left..<cursor.left, right: start.right..<cursor.right))
                open = nil
            } else if !isSame, open == nil {
                open = cursor
            }
            cursor = (cursor.left + (step.left == nil ? 0 : 1), cursor.right + (step.right == nil ? 0 : 1))
        }
        if let start = open { hunks.append(Hunk(left: start.left..<cursor.left, right: start.right..<cursor.right)) }
        return hunks
    }

    // The right words between the left words before and after a range of left words.
    func rightSpan(of range: Range<Int>, leftCount: Int, rightCount: Int) -> Range<Int> {
        var before = [Int](repeating: 0, count: leftCount + 1)
        var after = [Int](repeating: 0, count: leftCount + 1)
        var cursor = 0
        for step in steps {
            if let l = step.left { before[l] = cursor }
            if step.right != nil { cursor += 1 }
            if let l = step.left { after[l + 1] = cursor }
        }
        before[leftCount] = rightCount
        let low = range.lowerBound == 0 ? 0 : after[range.lowerBound]
        return low..<max(low, before[range.upperBound])
    }

    // The partner of each right word on the left, nil for a word the left lacks.
    func leftPartners(rightCount: Int) -> [Int?] {
        var partners = [Int?](repeating: nil, count: rightCount)
        for step in steps {
            if let r = step.right { partners[r] = step.left }
        }
        return partners
    }
}
