import Foundation

// The meeting's speakers from the split's clusters: numbered in the order first heard, the owner as 1, named where a voice
// or the calendar says who they are.
struct SpeakerCast {
    private(set) var speakers: [Meeting.Speaker] = []
    let order: [String]
    private let ids: [String: String]
    private let ownerCluster: String?
    private let ownerHasMicrophone: Bool

    init(clusters: [String], matches: [String: SpeakerNaming.Match], people: [VoiceMemory.Person], ownerHasMicrophone: Bool, ownerName: String) {
        let owner = people.first(where: \.isOwner)
        let ownerCluster = owner.flatMap { owner in matches.first { $0.value == .named(owner.id) }?.key }
        var order = ownerCluster.map { [$0] } ?? []
        for cluster in clusters where !order.contains(cluster) { order.append(cluster) }
        var next = ownerHasMicrophone || ownerCluster != nil ? 2 : 1
        var ids: [String: String] = [:]
        for cluster in order {
            ids[cluster] = Self.id(cluster == ownerCluster ? 1 : next)
            if cluster != ownerCluster { next += 1 }
        }
        self.order = order
        self.ids = ids
        self.ownerCluster = ownerCluster
        self.ownerHasMicrophone = ownerHasMicrophone
        if ownerHasMicrophone {
            speakers.append(Meeting.Speaker(id: MeetingTranscript.ownerID, name: ownerName, personId: owner?.id))
        }
        for cluster in order {
            var speaker = Meeting.Speaker(id: id(of: cluster), name: Self.numberedName(of: id(of: cluster)))
            switch matches[cluster] {
            case .named(let person):
                speaker.name = people.first { $0.id == person }?.name ?? speaker.name
                speaker.personId = person
            case .suggested(let person): speaker.suggestion = person
            case nil: break
            }
            speakers.append(speaker)
        }
    }

    func id(of cluster: String) -> String {
        ids[cluster] ?? Self.id(1)
    }

    // With the owner known and one other voice, the one other person invited is very likely that voice.
    mutating func guess(_ attendees: [String], hasPrint: (String) -> Bool) {
        let others = order.filter { $0 != ownerCluster }
        guard ownerHasMicrophone || ownerCluster != nil, attendees.count == 1, others.count == 1, let other = others.first,
              hasPrint(other), let index = speakers.firstIndex(where: { $0.id == id(of: other) }), speakers[index].personId == nil
        else { return }
        speakers[index].name = attendees[0]
        speakers[index].isGuess = true
    }

    static func id(_ number: Int) -> String {
        "speaker-\(number)"
    }

    static func numberedName(of id: String) -> String {
        SpeakerNaming.numberedName(Int(id.split(separator: "-").last ?? "") ?? 1)
    }
}
