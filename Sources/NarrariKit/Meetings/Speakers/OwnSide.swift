import Foundation

// Who is on the owner's microphone in a call: the owner, someone beside them who takes turns with them, or the far side
// heard through the speakers, left by echo removal; a voice that only sounds unlike the owner stays the owner.
struct OwnSide {
    enum Role: Equatable {
        case owner
        case guest
        case echo
    }

    // Kept apart from the system track's clusters, which the split names the same way.
    static let guestPrefix = "mic-"
    // Measured 24 Nov 2026 on 158 one-voice microphone tracks (echo, noise, a microphone changed mid-call): none split.
    static let ownerNear: Float = 0.40
    static let echoShare = 0.80
    static let handOvers = 2

    let ownerPrint: [Float]?
    let guestPrints: [String: [Float]]
    private let turns: [SpeakerSplit.Turn]
    private let roles: [String: Role]

    // A count the user chose keeps every voice the split finds as a person.
    init(_ split: SpeakerSplit, ownerPrint stored: [Float]?, farSpeech: [SpeakerSplit.Turn], chosen: Bool) {
        let turns = chosen ? split.turns : MeetingSpeakers.folded(split.turns)
        let speech = MeetingSpeakers.speechSeconds(turns)
        var roles = speech.keys.reduce(into: [String: Role]()) { roles, cluster in
            if Self.share(of: cluster, in: turns, during: farSpeech) >= Self.echoShare { roles[cluster] = .echo }
        }
        let voices = speech.filter { roles[$0.key] == nil }
        let owner = Self.owner(of: voices.isEmpty ? speech : voices, prints: split.prints, stored: stored)
        roles[owner ?? ""] = nil
        let references = [owner.flatMap { split.prints[$0] }, stored].compactMap(\.self)
        for cluster in voices.keys where cluster != owner {
            let far = split.prints[cluster].map { print in references.allSatisfy { SpeakerNaming.distance(print, $0) > Self.ownerNear } }
            if chosen || far == true && owner.map({ Self.handOvers(between: $0, and: cluster, in: turns) >= Self.handOvers }) == true {
                roles[cluster] = .guest
            }
        }
        ownerPrint = voices.isEmpty ? nil : owner.flatMap { split.prints[$0] }
        guestPrints = Dictionary(uniqueKeysWithValues: roles.filter { $0.value == .guest }.compactMap { cluster, _ in
            split.prints[cluster].map { (Self.guestPrefix + cluster, $0) }
        })
        self.turns = turns
        self.roles = roles
    }

    // A guest's word is under their prefixed cluster; the owner's and the echo's under none.
    func cluster(at word: Transcript.Word) -> String {
        guard let cluster = MeetingSpeakers.speaker(at: word, in: turns), roles[cluster] == .guest else { return "" }
        return Self.guestPrefix + cluster
    }

    func role(at word: Transcript.Word) -> Role {
        MeetingSpeakers.speaker(at: word, in: turns).flatMap { roles[$0] } ?? .owner
    }

    // The voice nearest the stored print when it is clear, else whoever talks most.
    private static func owner(of speech: [String: Double], prints: [String: [Float]], stored: [Float]?) -> String? {
        let nearest = stored.flatMap { stored in
            prints.filter { speech[$0.key] != nil }.map { (cluster: $0.key, distance: SpeakerNaming.distance($0.value, stored)) }
                .min { $0.distance < $1.distance }
        }
        if let nearest, nearest.distance <= SpeakerNaming.clear { return nearest.cluster }
        return speech.max { $0.value < $1.value }?.key
    }

    private static func handOvers(between owner: String, and other: String, in turns: [SpeakerSplit.Turn]) -> Int {
        let order = turns.sorted { $0.start < $1.start }.map(\.speaker).filter { $0 == owner || $0 == other }
        return zip(order, order.dropFirst()).filter { $0 != $1 }.count
    }

    private static func share(of cluster: String, in turns: [SpeakerSplit.Turn], during far: [SpeakerSplit.Turn]) -> Double {
        let own = turns.filter { $0.speaker == cluster }
        let total = own.reduce(0) { $0 + $1.end - $1.start }
        let shared = own.reduce(0) { sum, turn in
            sum + far.reduce(0) { $0 + max(0, min(turn.end, $1.end) - max(turn.start, $1.start)) }
        }
        return total > 0 ? shared / total : 0
    }
}
