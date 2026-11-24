import Foundation

// Runs the live-text model on the audio heard so far. Its instance loads when a dictation is confirmed and is let go
// after a few idle minutes, so it is not resident all day.
@MainActor
public final class LivePreview {
    private let transcriber: any Transcriber
    private let clock: any Clock<Duration>
    private var loop: Task<Void, Never>?
    private var idleUnload: Task<Void, Never>?

    private static let interval: Duration = .milliseconds(500)
    // The model pads every input to 15 s, so a window just under that keeps each pass at one fixed cost.
    private static let window = Int(14 * SpeechAudio.sampleRate)
    private static let minimumAudio = Int(0.5 * SpeechAudio.sampleRate)
    // Loading again takes about 0.1 s, so a burst of dictations shares one load and a quiet Mac gets the memory back.
    public static let idleLimit: Duration = .seconds(180)

    public init(transcriber: any Transcriber, clock: any Clock<Duration> = ContinuousClock()) {
        self.transcriber = transcriber
        self.clock = clock
    }

    public func start(
        reading recentSamples: @escaping @MainActor (Int) -> [Float],
        publish: @escaping @MainActor (String) -> Void
    ) {
        loop?.cancel()
        idleUnload?.cancel()
        idleUnload = nil
        loop = Task { [transcriber, clock] in
            do {
                try await transcriber.load()
            } catch {
                // The transcriber logs its own failures; a preview that can't load just shows no live text.
                return
            }
            while (try? await clock.sleep(for: Self.interval)) != nil {
                let samples = recentSamples(Self.window)
                guard samples.count >= Self.minimumAudio else { continue }
                let text: String
                do {
                    text = try await transcriber.transcribe(samples: samples).text
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                publish(text)
            }
        }
    }

    // The dictation ended; the instance stays loaded for the next one until the idle limit passes.
    public func stop() {
        guard let finishing = loop else { return }
        finishing.cancel()
        loop = nil
        idleUnload?.cancel()
        idleUnload = Task { [transcriber, clock] in
            guard (try? await clock.sleep(for: Self.idleLimit)) != nil else { return }
            await finishing.value
            await transcriber.unload()
        }
    }

    // Live text was turned off or the model files went away: unload once any pass in flight is done, and load
    // nothing until a later dictation starts again.
    public func release() async {
        let finishing = loop
        loop?.cancel()
        loop = nil
        idleUnload?.cancel()
        idleUnload = nil
        await finishing?.value
        await transcriber.unload()
    }
}
