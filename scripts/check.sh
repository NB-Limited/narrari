#!/usr/bin/env bash
# Source rules that need no build or certificate. Stops at the first broken rule.
# Takes an optional root, so scripts/check-rules.sh can run the rules on a tree of bad samples.
set -euo pipefail
cd "${1:-$(dirname "$0")/..}"
export LC_ALL=C

pin() {
  local tool=$1 want=$2 have=$3
  [ "$have" = "$want" ] && return
  echo "$tool $want is needed, found ${have:-none}: brew install $tool && brew pin $tool" >&2
  exit 1
}
pin periphery 3.8.0 "$(periphery version 2>/dev/null || true)"
pin shellcheck 0.11.0 "$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}' || true)"

# Reads file:line:text hits on stdin and fails with the fix if any are outside the rule's homes.
report() {
  local fix=$1 homes=" ${2:-} " found=0 file line rest
  while IFS=: read -r file line rest; do
    case $homes in *" $file "*) continue ;; esac
    echo "$file:$line: $fix"
    found=1
  done
  [ "$found" -eq 0 ] || exit 1
}

swift_grep() { grep -rnE --include='*.swift' "$@" 2>/dev/null || true; }

unmirrored_tests() {
  local test rel
  find tests -name '*Tests.swift' 2>/dev/null | sort | while read -r test; do
    rel=${test#tests/}
    [ -f "Sources/NarrariKit/${rel%Tests.swift}.swift" ] || echo "$test:1:"
  done
}

report "Wait on the event itself with until, a Gate or TestClock from tests/Support, never a sleep or yield." \
  "tests/Support/WaitLimit.swift" \
  < <(swift_grep 'Task\.sleep|Thread\.sleep|asyncAfter|usleep\(|Task\.yield' tests)

report "Name the test after a Sources/NarrariKit file it tests, at the same path, or delete it." \
  "" < <(unmirrored_tests)

report "Views never touch storage, files or the network; move this into Sources/NarrariKit and read it through a model." \
  "" < <(swift_grep -w 'SettingsStore|UserDefaults|FileManager|URLSession|JSONEncoder|JSONDecoder' App)

report "Declare every setting and its default in Sources/NarrariKit/Settings/." \
  "" < <(swift_grep '(^|[^[:alnum:]_])Setting\(' Sources App tests scripts | grep -v '^Sources/NarrariKit/Settings/' || true)

report "Declare the setting with its enum, Setting(\"key\", default: Kind.value), so SettingsStore reads and writes it by name." \
  "" < <(swift_grep 'Setting\("[^"]+", default: [A-Z][A-Za-z]+\.[a-z][A-Za-z]*\.[a-z][A-Za-z]*\)' Sources/NarrariKit/Settings)

misnamed_keys() {
  local file area
  for file in Sources/NarrariKit/Settings/*Settings.swift; do
    [ -f "$file" ] || continue
    area=$(sed -nE 's/^public enum ([A-Za-z]+)Settings \{.*/\1/p' "$file" | head -1 | tr '[:upper:]' '[:lower:]')
    grep -nE '"[a-z]+\.[A-Za-z]+"' /dev/null "$file" | grep -vE "\"$area\." || true
  done
}
report "Start the key with the enum's area: FooSettings keys are foo.<name>." "" < <(misnamed_keys)

report "Move this type to its concern's folder; Settings/*Settings.swift declares Setting values only." \
  "" < <(grep -nE '^public (enum|struct|final class) ' /dev/null Sources/NarrariKit/Settings/*Settings.swift 2>/dev/null \
  | grep -vE 'enum [A-Za-z]+Settings \{' || true)

unlisted_settings() {
  local file area hit name list=Sources/NarrariKit/Settings/SettingsList.swift
  for file in Sources/NarrariKit/Settings/*Settings.swift; do
    [ -f "$file" ] || continue
    area=$(sed -nE 's/^public enum ([A-Za-z]+Settings) \{.*/\1/p' "$file" | head -1)
    grep -nE '^[[:space:]]*public static let [A-Za-z]+ = Setting\(' /dev/null "$file" | while IFS= read -r hit; do
      name=$(sed -E 's/.*static let ([A-Za-z]+) = Setting\(.*/\1/' <<<"$hit")
      grep -qwF "$area.$name" "$list" 2>/dev/null || echo "$hit"
    done
  done
}
report "List this setting in Sources/NarrariKit/Settings/SettingsList.swift, so narrari settings shows and sets it." \
  "" < <(unlisted_settings)

unheard_change_keys() {
  local hit file type
  swift_grep 'static let changeKey' Sources | while IFS= read -r hit; do
    file=${hit%%:*}
    type=$(basename "$file" .swift)
    swift_grep "(updates\(of:|follow\().*$type\.changeKey" Sources | grep -q . || echo "$hit"
  done
}
report "Nothing listens for this changeKey; listen for it with SettingsChanges.follow or updates(of:), or stop posting it." \
  "" < <(unheard_change_keys)

report "Take the store as a parameter without a default and pass it in from App/NarrariApp.swift; a .shared default lets a test read the owner's real data." \
  "" < <(swift_grep ':[[:space:]]*(any[[:space:]]+)?[A-Za-z]+[[:space:]]*=[[:space:]]*(([A-Z][A-Za-z]*)?\.(shared|narrari)|AppPaths\.[a-z]+)[[:space:]]*([,)]|$)' Sources)

# The kit's shared instances are the real stores and readers of the owner's data; only the app's root picks them.
kit_shared_files() { grep -rlE --include='*.swift' 'static let shared = ' Sources/NarrariKit 2>/dev/null | sort || true; }
shared_outside_root() {
  local types
  types=$(kit_shared_files | xargs -n1 basename 2>/dev/null | sed 's/\.swift$//' | paste -sd'|' -)
  swift_grep -E "(^|[^A-Za-z0-9_)?!]|\])\.shared\b${types:+|\b($types)\.shared\b}" Sources App tests
}
report "Pick the real store only in App/NarrariApp.swift and pass it in, so no other code, view or test reaches the owner's data." \
  "App/NarrariApp.swift $(kit_shared_files | tr '\n' ' ')" < <(shared_outside_root)

report "Make outside requests with OutsideService.makeSession(), which refuses redirects and keeps nothing on disk." \
  "Sources/NarrariKit/Support/OutsideService.swift" \
  < <(swift_grep 'URLSession(\(|\.shared)|URLSessionConfiguration\.' Sources App scripts/dev)

report "Use NotificationCenter.updates from Support, which removes the observer when the stream ends." \
  "Sources/NarrariKit/Support/NotificationUpdates.swift" \
  < <(swift_grep 'addObserver\(' Sources)

report "Read and request microphone access through Permissions, the one owner of that state." \
  "Sources/NarrariKit/Input/Permissions.swift" \
  < <(swift_grep 'AVCaptureDevice\.(authorizationStatus|requestAccess)' Sources App)

report "Logic never reads Pill types; put the fact on the model type (for example Notice.isError) and let the Pill read it." \
  "" < <(swift_grep '\bPill(Label|Motion|State|Capsule)\b' Sources/NarrariKit/Dictation Sources/NarrariKit/Audio \
  Sources/NarrariKit/Input Sources/NarrariKit/Output Sources/NarrariKit/Speech)

shared_log_names() {
  local call
  grep -rhoE --include='*.swift' 'Log\.(event|failure|timing|count)\("[^"]+"' Sources App scripts/dev 2>/dev/null \
    | sort | uniq -d | while IFS= read -r call; do grep -rnF --include='*.swift' "$call" Sources App scripts/dev; done
}
report "Give this Log call a name of its own, so a log line points at one place." "" < <(shared_log_names)

report "Format percentages with MetricText.percent so every screen reads them the same." \
  "Sources/NarrariKit/Support/ModelMetricReadings.swift" < <(swift_grep '\.percent\.precision' Sources App)

# A page keeps no copy of a setting: it reads each one through SettingsMirror, which redraws it when anything changes it.
copied_settings() {
  find Sources/NarrariKit -name '*PageModel.swift' -o -name 'MenuPanel*.swift' 2>/dev/null | sort | xargs grep -nE \
    '\bSettingsStore\b|^[[:space:]]+(self\.)?[a-z][A-Za-z]* = settings(\.store)?(\[|\.value\()' /dev/null || true
}
report "Read the setting through SettingsMirror each time, settings[Setting], so the page shows a change made anywhere." \
  "" < <(copied_settings)

report "Name the page's on-appear entry point appear()." \
  "" < <(grep -nE 'public func (reload|refresh)\(' /dev/null Sources/NarrariKit/*/*PageModel.swift 2>/dev/null || true)

# A writer that creates a file with the default permissions must narrow it within the next few lines.
open_writes() {
  local hit file line
  swift_grep -E '\.write\(to:|ExtAudioFileCreateWithURL\(|forWriting:|createFile\(' Sources | while IFS= read -r hit; do
    file=${hit%%:*}
    line=${hit#*:}
    line=${line%%:*}
    sed -n "${line},$((line + 8))p" "$file" | grep -qE 'makeOwnerOnly|ownerOnlyFile' || echo "$hit"
  done
}
report "Create the file for its owner alone: pass AppPaths.ownerOnlyFile to createFile, or call AppPaths.makeOwnerOnly right after the write." \
  "" < <(open_writes)

report "Read and write settings files through JSONFile, which re-reads before it writes." \
  "Sources/NarrariKit/Support/JSONFile.swift" < <(swift_grep 'prettyPrinted' Sources)

report "Read the reducesMotion environment value, or ReduceMotion where no view is, which also follows the Follow Reduce Motion switch." \
  "Sources/NarrariKit/Settings/ReduceMotion.swift" \
  < <(swift_grep 'accessibility(DisplayShould)?ReduceMotion' Sources App tests)

report "Show error.problem(or:) with the feature's fixed problem; system text never reaches the screen, a file or the log (DESIGN.md, Problems)." \
  "" < <(swift_grep 'localizedDescription' Sources App tests scripts/dev)

empty_catches() {
  find Sources App tests scripts/dev -name '*.swift' 2>/dev/null | sort | xargs awk '
    FNR == 1 { pending = 0 }
    /catch[^{]*\{[[:space:]]*\}/ { print FILENAME ":" FNR ":"; pending = 0; next }
    pending && /^[[:space:]]*\/\// { next }
    pending && /^[[:space:]]*\}/ { print FILENAME ":" pending ":" }
    { pending = 0 }
    /catch[^{]*\{[[:space:]]*$/ { pending = FNR }' /dev/null
}
report "Handle the error: log it with Log.failure and show its problem, or let it throw; an empty catch hides a failure." \
  "" < <(empty_catches)

report "Log through Log with a fixed name from Sources/NarrariKit/Support/Log/Log.swift, never print or another logger." \
  "Sources/NarrariKit/Support/Log/Log.swift" \
  < <(swift_grep '(^|[^[:alnum:]_.])(print|NSLog|os_log|Logger)\(' Sources App tests)

report "Name controls with .iconLabel or a quiet line; Narrari never shows the system tooltip (DESIGN.md, Controls)." \
  "" < <(swift_grep '\.help\(' App)

report "Use Motion.Curve (enter, exit, lift) from App/Tokens.swift instead of writing control points." \
  "App/Tokens.swift" < <(swift_grep 'timingCurve\(|controlPoints:|UnitCurve\.bezier' App)

report "Use a Typeface step or a Symbol size from App/Tokens.swift." \
  "App/Tokens.swift" < <(swift_grep 'NSFont\.systemFont\(ofSize: [0-9]|Font\.system\(size: [0-9]' App)

report "Draw field frames with .fieldSurface(isError:) from App/Components/Fields/Fields.swift." \
  "App/Components/Fields/Fields.swift" \
  < <(swift_grep '(errorInk|controlEdge)[[:space:]]*:[[:space:]]*(Color\.)?(errorInk|controlEdge)|strokeBorder\(.*errorInk' App)

unused_tokens() {
  local tokens=App/Tokens.swift unused
  [ -f "$tokens" ] || return 0
  unused=$(comm -12 \
    <(sed -nE 's/^[[:space:]]*(public )?static let ([A-Za-z_]+).*/\2/p' "$tokens" | sort -u) \
    <(grep -rhowE --include='*.swift' '[A-Za-z_][A-Za-z0-9_]*' App Sources | sort | uniq -c | awk '$1 == 1 {print $2}' | sort))
  [ -z "$unused" ] || grep -nwE "static let ($(paste -sd'|' - <<<"$unused"))" /dev/null "$tokens"
}
report "This token in App/Tokens.swift has no user; delete it." "" < <(unused_tokens)

stray_app_files() {
  local file
  find App -maxdepth 1 -name '*.swift' 2>/dev/null | sort | while read -r file; do
    case ${file#App/} in NarrariApp.swift | MainWindow.swift | MainView.swift | AboutPanel.swift | Tokens.swift) ;; *) echo "$file:1:" ;; esac
  done
}
report "Put views in the App/ folder for their concern (Pill, Menu, Settings, History, Components)." "" < <(stray_app_files)

report "Put the control in the App/Components/ folder of its kind: Buttons, Fields, Labels, Rows or Support." \
  "" < <(find App/Components -maxdepth 1 -name '*.swift' 2>/dev/null | sort | sed 's/$/:1:/')

# A borderless panel floats over other apps and must say whether a share shows it; a titled window is one the person
# opened, such as the main window, and is shared like any other app's.
unshared_panels() {
  local file
  grep -rlE --include='*.swift' 'styleMask:[^]]*\.borderless' App 2>/dev/null | sort | while read -r file; do
    grep -q 'sharingType' "$file" || grep -nE 'styleMask:[^]]*\.borderless' /dev/null "$file" | head -1
  done
}
report "Set sharingType on this panel: .none for a surface over other apps (subclass UnsharedPanel), its parent's for a child window." \
  "" < <(unshared_panels)

crowded_folders() {
  local folder
  find Sources App tests scripts -type d 2>/dev/null | sort | while read -r folder; do
    [ "$(find "$folder" -maxdepth 1 -name '*.swift' | wc -l)" -le 20 ] || echo "$folder:1:"
  done
}
report "Split this folder by concern; past 20 Swift files a folder no longer says what it holds (nb-suite lint.md)." "" < <(crowded_folders)

dashes=$'\xe2\x80\x94|\xe2\x80\x93'
dashed_docs() {
  local doc
  for doc in README.md AGENTS.md DESIGN.md; do
    [ ! -f "$doc" ] || grep -nE "$dashes" /dev/null "$doc" || true
  done
}
report "Replace the em or en dash with a comma, colon, full stop or plain hyphen." \
  "" < <(swift_grep "$dashes" Sources App tests scripts; dashed_docs)

shellcheck scripts/*.sh
swiftlint lint --quiet

echo "check.sh: all rules pass"
