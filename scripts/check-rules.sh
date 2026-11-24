#!/usr/bin/env bash
# Proves every grep rule in check.sh fires: each bad sample goes in a tree of its own, and check.sh must fail there
# with the rule's message. Running check.sh on the repo itself proves each rule passes its home.
set -euo pipefail
cd "$(dirname "$0")/.."

missed=0
expect() {
  local path=$1 fix=$2 content=$3 tree out
  tree=$(mktemp -d)
  mkdir -p "$tree/$(dirname "$path")"
  printf '%b\n' "$content" > "$tree/$path"
  out=$(bash scripts/check.sh "$tree" 2>&1) && out=""
  rm -rf "$tree"
  case $out in *"$path:"*"$fix"*) ;; *) echo "did not fire on $path: $fix"; missed=1 ;; esac
}

settings=Sources/NarrariKit/Settings/FooSettings.swift
expect tests/Words/WordsTests.swift "never a sleep or yield" 'try await Task.sleep(for: .seconds(1))'
expect tests/Words/MissingTests.swift "Name the test after" 'struct MissingTests {}'
expect App/Menu/Bad.swift "Views never touch storage" 'let defaults = UserDefaults.standard'
expect App/Menu/Bad.swift "Declare every setting and its default" 'let size = Setting("menu.size", default: 1)'
expect $settings "Declare the setting with its enum" \
  'public enum FooSettings {\n    public static let kind = Setting("foo.kind", default: Kind.plain.rawValue)\n}'
expect $settings "Start the key with the enum's area" \
  'public enum FooSettings {\n    public static let size = Setting("bar.size", default: 1)\n}'
expect $settings "declares Setting values only" 'public struct Foo {}'
expect $settings "List this setting" 'public enum FooSettings {\n    public static let size = Setting("foo.size", default: 1)\n}'
expect Sources/NarrariKit/Words/WordStore.swift "Nothing listens for this changeKey" 'static let changeKey = "words"'
expect Sources/NarrariKit/Words/WordPage.swift "a .shared default" 'init(store: WordStore = .shared) {}'
expect App/Menu/Look.swift "Pick the real store only in App/NarrariApp.swift" 'let looks = PillLookModel(settings: .shared)'
expect Sources/NarrariKit/Words/Fetch.swift "OutsideService.makeSession()" 'let session = URLSession.shared'
expect Sources/NarrariKit/Words/Watch.swift "Use NotificationCenter.updates" \
  'NotificationCenter.default.addObserver(forName: .words, object: nil, queue: nil) { _ in }'
expect App/Menu/Mic.swift "through Permissions" 'let status = AVCaptureDevice.authorizationStatus(for: .audio)'
expect Sources/NarrariKit/Dictation/Look.swift "Logic never reads Pill types" 'let delay = PillMotion.out'
expect Sources/NarrariKit/Words/Twice.swift "a name of its own" 'Log.event("words-saved")\nLog.event("words-saved")'
expect App/Menu/Share.swift "MetricText.percent" 'let text = share.formatted(.percent.precision(.fractionLength(0)))'
expect Sources/NarrariKit/Words/WordsPageModel.swift "appear()" 'public func refresh() {}'
expect Sources/NarrariKit/Words/WordsPageModel.swift "through SettingsMirror" '    init(settings: SettingsStore) {}'
expect Sources/NarrariKit/Words/WordsPageModel.swift "through SettingsMirror" '        isOn = settings[WordsSettings.isOn]'
expect Sources/NarrariKit/Words/Save.swift "through JSONFile" 'encoder.outputFormatting = .prettyPrinted'
expect Sources/NarrariKit/Words/Keep.swift "for its owner alone" 'try data.write(to: url, options: .atomic)'
expect App/Menu/Motion.swift "reducesMotion environment value" 'let isOn = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion'
expect Sources/NarrariKit/Words/Say.swift "never print or another logger" 'print("words")'
expect App/Menu/Tip.swift "system tooltip" 'Text("Words").help("Your words")'
expect App/Menu/Curve.swift "Motion.Curve" '.animation(.timingCurve(0.2, 0, 0, 1, duration: 0.3), value: isOn)'
expect App/Menu/Size.swift "Typeface step" 'let font = Font.system(size: 12)'
expect App/Menu/Frame.swift "fieldSurface" '.overlay(shape.strokeBorder(isError ? Color.errorInk : Color.controlEdge))'
expect App/Tokens.swift "has no user" 'enum Spacing {\n    static let lonelyGap = 1\n}'
expect App/Stray.swift "Put views in the App/ folder" 'struct Stray {}'
expect App/Components/Loose.swift "folder of its kind" 'struct Loose {}'
expect App/Menu/Float.swift "Set sharingType" 'let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)'
expect README.md "em or en dash" 'Words \xe2\x80\x94 spelled right.'

crowded=$(mktemp -d)
mkdir -p "$crowded/Sources/NarrariKit/Words"
for n in $(seq 21); do echo "struct Word$n {}" > "$crowded/Sources/NarrariKit/Words/Word$n.swift"; done
case $(bash scripts/check.sh "$crowded" 2>&1) in
  *"Sources/NarrariKit/Words:"*"Split this folder by concern"*) ;;
  *) echo "did not fire on a folder of 21 files: Split this folder by concern"; missed=1 ;;
esac
rm -rf "$crowded"

[ "$missed" -eq 0 ] || exit 1
echo "check-rules.sh: every rule fired on its bad sample"
