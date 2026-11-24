import Foundation

extension DictationSession {
    // Narrari's own windows never count as the app being dictated into, so opening one keeps the mode chosen.
    public func frontmostAppChanged() {
        let app = frontmostApp() ?? ""
        guard app != ownApp else { return }
        lastOutsideApp = app
        resolver.appChanged(to: app)
        refreshModeChoice(for: app)
    }

    // With a Narrari window in front, the text goes to the app used before it; with none known, no app.
    func dictatedApp() -> String {
        let app = frontmostApp() ?? ""
        guard app == ownApp else {
            lastOutsideApp = app
            return app
        }
        return lastOutsideApp ?? ""
    }

    public func refreshModeChoice() {
        refreshModeChoice(for: modeChoice.app)
    }

    public func selectMode(_ id: String) {
        let app = modeChoice.app
        guard let mode = resolver.select(id, for: app, in: loadModes()) else { return }
        Log.event("mode-selected-menu")
        show(.mode(mode.name))
        refreshModeChoice(for: app)
    }

    private func refreshModeChoice(for app: String) {
        let book = loadModes()
        modeChoice = ModeChoice(app: app, modes: book.modes(for: app), current: resolver.resolve(for: app, in: book))
    }

    // The one place a mode supplies its settings. Switching clean-up off globally beats a mode that has it on;
    // Command E and a trigger word then change only the dictation in progress.
    func modeChoices(for app: String) -> (
        name: String, prompt: Prompt, isCleanupOn: Bool, transcriber: any Transcriber
    ) {
        let mode = resolver.resolve(for: app, in: loadModes())
        if mode.id == Mode.dictation.id { Log.event("mode-dictation") } else { Log.event("mode-own") }
        var outside: (any Transcriber)?
        switch mode.speech {
        case .local:
            Log.event("speech-on-this-mac")
        case .outside:
            outside = outsideTranscriber()
            if outside == nil { Log.event("speech-outside-not-set-up") } else { Log.event("speech-outside") }
        }
        return (
            mode.name,
            pipeline.prompt(id: mode.promptID),
            mode.isCleanupOn && settings.value(CleanupSettings.isEnabled),
            outside ?? transcriber
        )
    }

    private func loadModes() -> ModeBook {
        do {
            return try modes.load()
        } catch {
            Log.failure("modes-load-dictation", error: error)
            return ModeBook()
        }
    }

    public func cycleMode() {
        guard phase != .recording else { return }
        let app = dictatedApp()
        let book = loadModes()
        show(.mode((resolver.cycle(for: app, in: book) ?? resolver.resolve(for: app, in: book)).name))
        refreshModeChoice(for: app)
    }
}
