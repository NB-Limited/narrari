import AVFoundation
import Foundation

public enum Sound: Sendable, CaseIterable {
    case start
    case stop
    case ignored

    fileprivate var fileKind: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .ignored: "discard"
        }
    }

    fileprivate var systemName: String {
        switch self {
        case .start: "Tink"
        case .stop: "Pop"
        case .ignored: "Funk"
        }
    }
}

public enum SoundSet: String, CaseIterable, Sendable, Identifiable {
    case trace
    case swell
    case rim
    case bloom
    case bell
    case wood
    case low
    case glass
    case mallet
    case classic

    public static let standard = SoundSet.trace

    public var id: Self { self }
    public var name: String { rawValue.capitalized }

    public func fileName(for sound: Sound) -> String {
        self == .classic ? "\(sound.systemName).aiff" : "\(rawValue)-\(sound.fileKind).wav"
    }

    // Classic is the system's own sounds; every other set is made by scripts/make_sounds.py.
    public func url(for sound: Sound) -> URL? {
        let name = fileName(for: sound)
        if self == .classic { return URL(filePath: "/System/Library/Sounds/\(name)") }
        return Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Sounds")
    }
}

@MainActor
public protocol SoundClip: AnyObject {
    var duration: TimeInterval { get }
    func play() -> Bool
}

@MainActor
public protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound) async
}

// Keeps the chosen set's three sounds decoded and ready, so a dictation's first sound starts at once.
@MainActor
public final class Sounds: SoundPlaying {
    public typealias Loader = @MainActor (SoundSet, Sound) -> (any SoundClip)?

    static let previewGap: Duration = .milliseconds(300)

    private let settings: SettingsStore
    private let clock: any Clock<Duration>
    private let load: Loader
    private var loaded: (set: SoundSet, clips: [Sound: any SoundClip])?
    private var following: Task<Void, Never>?

    // The clips load once `connect` has joined the audio output, so a launch never waits on it.
    public init(
        settings: SettingsStore, clock: any Clock<Duration> = ContinuousClock(), load: @escaping Loader = Sounds.loadFile,
        connect: @escaping @Sendable () async -> Void = Sounds.connectOutput
    ) {
        self.settings = settings
        self.clock = clock
        self.load = load
        let updates = SettingsChanges.updates(of: [DictationSettings.soundSet.key])
        following = Task { [weak self] in
            await connect()
            _ = self?.chosenClips()
            for await _ in updates { _ = self?.chosenClips() }
        }
    }

    isolated deinit {
        following?.cancel()
    }

    public static func loadFile(_ set: SoundSet, _ sound: Sound) -> (any SoundClip)? {
        set.url(for: sound).flatMap(FileClip.init)
    }

    // The first player made ready joins the process to the audio output, a third of a second; every one after it is ready at once.
    @concurrent
    public nonisolated static func connectOutput() async {
        let start = ContinuousClock.now
        guard let url = SoundSet.standard.url(for: .start) else { return }
        (try? AVAudioPlayer(contentsOf: url))?.prepareToPlay()
        Log.timing("sound-output-connected", seconds: (ContinuousClock.now - start) / .seconds(1))
    }

    // Waits until the sound has played, so muting other audio afterwards never cuts it off.
    public func play(_ sound: Sound) async {
        guard settings.value(DictationSettings.playsSounds) else { return }
        await play(sound, from: chosenClips())
    }

    public func preview(_ set: SoundSet) async {
        let clips = clips(for: set)
        guard await play(.start, from: clips), (try? await clock.sleep(for: Self.previewGap)) != nil else { return }
        await play(.stop, from: clips)
    }

    @discardableResult
    private func play(_ sound: Sound, from clips: [Sound: any SoundClip]) async -> Bool {
        guard let clip = clips[sound] else { return false }
        guard clip.play() else {
            Log.failure("sound")
            return false
        }
        return (try? await clock.sleep(for: .seconds(clip.duration))) != nil
    }

    private func chosenClips() -> [Sound: any SoundClip] {
        let set = settings.value(DictationSettings.soundSet)
        let clips = clips(for: set)
        loaded = (set, clips)
        return clips
    }

    private func clips(for set: SoundSet) -> [Sound: any SoundClip] {
        if let loaded, loaded.set == set { return loaded.clips }
        var clips: [Sound: any SoundClip] = [:]
        for sound in Sound.allCases {
            if let clip = load(set, sound) {
                clips[sound] = clip
            } else {
                Log.failure("sound-unavailable")
            }
        }
        return clips
    }
}

private final class FileClip: SoundClip {
    private let player: AVAudioPlayer

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        self.player = player
    }

    var duration: TimeInterval { player.duration }

    func play() -> Bool {
        player.currentTime = 0
        return player.play()
    }
}
