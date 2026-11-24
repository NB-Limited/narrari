# Narrari

Dictation and meeting notes for the Mac, in a menu bar app. Speech is transcribed on the Mac. No account, no cloud, no telemetry.

NB Limited built Narrari and made it open source because we think it is absurd that so many companies charge for this kind of tool and make you share your data with them.

Status: early software, built and used every day by its author. Source only: you build it yourself.

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode 27 (built and tested with 27.2)
- SwiftLint, Periphery, ShellCheck and XcodeGen: `brew install swiftlint periphery shellcheck xcodegen`
- Apple's Metal toolchain, for the app build: `xcodebuild -downloadComponent MetalToolchain`
- An Apple Development certificate for the app build (Xcode, Settings, Accounts, Manage Certificates), so macOS keeps the app's permissions across rebuilds.

## Build

```sh
swift build               # build the logic package
swift test                # run the tests
bash scripts/check.sh     # source rules, ShellCheck and SwiftLint, in under a second
bash scripts/ci.sh        # all of the above, the app build and Periphery; needs the certificate
bash scripts/install.sh   # the same, then install to /Applications and open
```

## Dictation

- Hold the dictation key (Right ⌘ by default) and speak; the text is pasted where you type when you let go.
- Tap the key instead to dictate hands-free until the next press. Escape throws the dictation away.
- Shows the words live in a small recorder while you speak, and says so when the microphone gives no sound.
- Cleans up the text (punctuation, filler words) with a model that runs inside the app. ⌘E turns clean-up off or on for one dictation.
- Prompts decide how the text is cleaned up. Built in: Tidy, Email, Message, and Agent brief, which puts each request to an AI tool on its own line. A trigger phrase at the start, such as "write email", picks a prompt for one dictation.
- A dictionary of words to spell right and phrases to replace.
- Spoken marks, off by default: say "new line" or "period" and the line break or mark is written instead.
- Modes per app: a different prompt or speech setting for Mail than for Slack.
- History of every dictation with its audio, to transcribe one again or clean it up with another prompt.
- Transcribes audio and video files.
- Puts your clipboard back after pasting, and mutes other sound while you dictate.
- ⌃⌥V pastes the last dictation again. When Narrari can't paste, the text stays on the clipboard for ⌘V.
- Other shortcuts open Narrari or Settings, switch mode or record a meeting, and may use a right-hand modifier only, such as Right ⌘ M.

## Meetings

- Notices when a call starts in Zoom, Teams, a browser or any other app, and offers to record it, or starts by itself if you turn that on. "Record a meeting" starts one by hand, for a meeting in a room.
- Records your microphone and the other side as two tracks, and shows the words live.
- Checks each track while it records, and warns on the meeting bar when one stops or records badly.
- After the call: a transcript with who said what on both sides, including a second person at your microphone, and a summary from a template you can edit. An untitled meeting is named from its summary.
- Shows the language spoken; choose another to rewrite the summary in it. You can also set how many people spoke.
- Knows people by voice once you name a speaker, so the next meeting names them by itself. Numbers only, never audio; forget a person in Settings, People.
- Takes the title and people from your calendar, and can read the names shown in a Zoom or Teams window (off by default).
- Import a recording to get the same transcript, speakers and summary.
- The recorder, the corner chip and the call notice are hidden from screen sharing and recording.
- Search across titles, people, notes, summaries and transcripts; click a line to hear it.

## Command line

`scripts/install.sh` links the app's own executable as `~/.local/bin/narrari`, so the command reads the same settings and log as the app.

```sh
narrari logs --last 2h > narrari.log   # the app's log lines, oldest first; never dictated text
narrari doctor                          # what someone helping you needs; ! marks a problem
narrari settings                        # every setting, its value and default; * marks the changed ones
narrari settings set pill.look clear    # also get <key> and reset <key>
narrari shortcuts set meeting right-cmd+m  # or ctrl+opt+m, or ⌃⌥M; shortcuts alone lists them, clear <action> removes one
narrari dictionary add Kubernetes          # also remove, replace <phrase> <text>, unreplace, mark, unmark, list
narrari prompts add "Short reply" --text reply.txt   # long text from a file, or - for stdin; also show, edit, remove
narrari modes app com.apple.mail <mode ids>          # which modes an app uses; also add, edit, remove, default, unapp
narrari templates list                     # summary templates; also show, add, duplicate, edit, remove, default
narrari people rename <id> "Boris Ivanov"  # people known by voice; also list and forget
narrari meetings list --since 2026-11-01   # newest first
narrari meetings show <id> --part summary  # one meeting, or only its summary, notes or transcript
narrari meetings search budget             # titles, names, notes, summaries, transcripts
narrari dictations search invoice          # list, show and search work the same way for dictations
```

A change goes through the same checks as Settings, and a running Narrari uses it at once. Built-in prompts and templates are read-only; duplicate one to edit it. Every list takes `--json`.

`doctor` exits 1 when it marks a problem. It never shows service keys, dictated text or any meeting's title, names or words: meetings are counted only.

## AI tools

`narrari mcp` lets an AI tool list, search and read your meetings and dictations. It only reads, talks over stdin and stdout, and opens no network port. To add it to Claude Code:

```sh
claude mcp add narrari -- ~/.local/bin/narrari mcp
```

Other tools take the command `~/.local/bin/narrari` with the argument `mcp`. What the tool reads goes wherever that tool sends it.

## Permissions

| Permission | Why |
|---|---|
| Microphone | Hears what you dictate. |
| Accessibility | Watches the dictation key and pastes the text. Without it, a dictation started from the menu ends on the clipboard. |
| System audio recording | Records the other side of a call. macOS asks at your first recording; without it a meeting is recorded from the microphone alone. |
| Calendar | Optional. Names a meeting and who is in it. |

## Your data

- Everything stays in `~/Library/Application Support/Narrari`: history and audio in `History`, meetings in `Meetings`, models in `Models`, summary templates in `Templates`, the people known by voice in `people.json`, prompts, dictionary and modes as JSON files.
- History and audio are deleted after 7 days by default; change it in Settings, History. A meeting's audio has its own setting there, also 7 days by default, and a pinned meeting keeps it; its transcript, summary and notes stay until you delete the meeting.
- Service keys are kept in the Keychain, never in files.
- Outside services are off. Text or audio leaves the Mac only if you enter an outside speech or clean-up service yourself. Its address must be https, or http on this Mac. A meeting's summary uses that service only when you choose it as the summary model in Settings, Summaries.

## Models and credits

| Used for | Model or library | Licence |
|---|---|---|
| Speech | [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) by Moondream, NVIDIA Parakeet TDT 0.6B [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), converted by [FluidInference](https://huggingface.co/FluidInference) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Dictionary words | [Parakeet CTC 110M](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml), converted from NVIDIA [Parakeet TDT-CTC 110M](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m), downloaded with the first word you add | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Who spoke in a meeting | [Speaker diarization models](https://huggingface.co/FluidInference/speaker-diarization-coreml) by Fluid Inference, from pyannote community-1, WeSpeaker and BUT Speech@FIT | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| Removing echo from a meeting's microphone | LocalVQE v1.3, run by FluidAudio | Apache-2.0 |
| Finding speech for the echo check | Silero VAD, run by FluidAudio | MIT |
| Clean-up and meeting summaries | Qwen3.5 2B MLX 8-bit, 4B MLX 4-bit and 0.8B MLX 8-bit | Apache-2.0 |
| Running the speech models | [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| Running the clean-up model | [mlx-swift](https://github.com/ml-explore/mlx-swift) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| Downloading models, tokenizer | [swift-huggingface](https://github.com/huggingface/swift-huggingface) and [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache-2.0 |
| Wordmark font | Source Serif 4 | SIL OFL 1.1 |

Models download on first use, more than a gigabyte in total.

## Contributing

Anyone may read, build, fork and learn from the code. Pull requests and issues are open to invited contributors only; see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## License

Copyright (C) 2026 Nikola Baburov.

Narrari is free software under the [GNU General Public License v3.0](LICENSE). You may use, change and share it, and versions you distribute must stay under the same licence. For a commercial licence without that condition, contact [NB Limited](https://nb-limited.com).

The licence covers the code. The name Narrari, the wordmark and the icon belong to NB Limited, so a fork needs its own name and icon.
