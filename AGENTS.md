# Narrari

Native macOS menu bar app for dictation and meeting notes. Swift 6, SwiftUI, Apple Silicon, macOS 15 or later. GPL-3.0, copyright Nikola Baburov.

## Rules

- Every line is written here. Never copy code from another app or from any GPL or unlicensed source, because the copyright must stay with one holder.
- New dependencies need a licence compatible with GPL-3.0 and an exact version pin.
- Local first: nothing leaves the Mac unless the user entered an outside service themselves.
- Dictated text, meeting words, people's names and audio never go into logs. `Log` takes fixed names only.
- An error Narrari throws gives a `Problem`; screens and files take its message or code, never system text (DESIGN.md, Problems).
- All logic lives in `Sources/NarrariKit/`, one folder per concern. `App/` holds views and wiring only.
- Every setting and its default lives in `Sources/NarrariKit/Settings/`.
- Tests live in `tests/`, mirroring `Sources/NarrariKit/`. Mock only at system boundaries.
- Stores and permission reads are passed in, never defaulted to `.shared` or the system. `App/NarrariApp.swift` is the one place that picks the real ones, so no test can reach real data or ask the system on the main thread.
- A standard a script can check goes into `scripts/check.sh`, with a bad sample in `scripts/check-rules.sh`. No exception lists and no disable comments: fix the hit.
- UI work: read `DESIGN.md` first; it is the design system.

## Commands

- `swift build`: compile the logic package.
- `bash scripts/check.sh`: tool versions, the grep rules, ShellCheck and SwiftLint, in under a second, no certificate.
- `bash scripts/ci.sh`: check.sh, its rule self-test, `swift build`, `swift test`, the app build and Periphery; needs an Apple Development certificate.
- `bash scripts/install.sh`: build, install to `/Applications`, open.
- `swift build --product narrari-dev && .build/debug/narrari-dev meeting rig [--quick]`: records test sound through the real meeting recorder on BlackHole 16ch and scores each track; run it after any audio change. It never asks for access, changes no default device and puts BlackHole's rate back.
- `swift build -c release --product narrari-dev && .build/release/narrari-dev speed [--json]`: times search, lists, history and clean-up on made-up data against the budgets in `scripts/dev/SpeedCheck.swift` and fails on a miss; run it after any change to a store or search. Not in CI, where shared runners make timings noise.
- `swift build -c release --product narrari-dev && .build/release/narrari-dev dictation-replay text|ahead <out folder>`: replays your own dictations, `text` through clean-up whole against the app's pipeline, `ahead` as sentence runs seen while speaking; its files and output hold counts, times and 8 character ids only, never a word.
- `/usr/bin/log show --last 5m --predicate 'subsystem == "com.nb-limited.narrari"'`: read the app's log. Use the full path, because zsh has its own `log`. A launch logs `timing launch-*` and `timing cold-start` as seconds since the process started; each meeting step logs `timing meeting-step-*`.

`Narrari.xcodeproj` is generated from `project.yml` and is not committed.
