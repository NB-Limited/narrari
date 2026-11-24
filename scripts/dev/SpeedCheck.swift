import Foundation
import NarrariKit

enum SpeedRow: String, CaseIterable, Encodable {
    case meetingKeystroke50 = "meeting search, keystroke, 50 meetings"
    case meetingKeystroke200 = "meeting search, keystroke, 200 meetings"
    case meetingFirstSearch = "meeting search, first after launch, 200 meetings"
    case meetingSearchMemory = "meeting search, memory it holds, 200 meetings"
    case meetingsFirstList = "meetings list, first read, 200 meetings"
    case meetingsListAfterChange = "meetings list, read after a change, 200 meetings"
    case meetingOpen = "meeting open, one-hour transcript"
    case historyAdd500 = "history, add a dictation, 500"
    case historyAdd2000 = "history, add a dictation, 2,000"
    case historyAdd10000 = "history, add a dictation, 10,000"
    case historySearch500 = "history search, 500"
    case historySearch2000 = "history search, 2,000"
    case historySearch10000 = "history search, 10,000"
    case historyFirstSearch10000 = "history search, first after launch, 10,000"
    case historySearchMemory10000 = "history search, memory it holds, 10,000"
    case historyFirstList2000 = "history list, first read, 2,000"
    case historyFirstList10000 = "history list, first read, 10,000"
    case historyDays10000 = "history grouped by day, 10,000"
    case cleanupLoad = "clean-up model load"
    case cleanup15 = "clean-up, 15 words"
    case cleanup66 = "clean-up, 66 words"
    case cleanup236 = "clean-up, 236 words"

    // The budgets: about twice the median measured on main on 24 Nov 2026, rounded up. Milliseconds, memory in MB.
    var budget: Double {
        switch self {
        case .meetingKeystroke50: 8
        case .meetingKeystroke200: 25
        case .meetingFirstSearch: 500
        case .meetingSearchMemory: 100
        case .meetingsFirstList: 20
        case .meetingsListAfterChange: 6
        case .meetingOpen: 2
        case .historyAdd500: 1
        case .historyAdd2000: 2
        case .historyAdd10000: 10
        case .historySearch500: 1
        case .historySearch2000: 3
        case .historySearch10000: 16
        case .historyFirstSearch10000: 70
        case .historySearchMemory10000: 20
        case .historyFirstList2000: 30
        case .historyFirstList10000: 150
        case .historyDays10000: 10
        case .cleanupLoad: 700
        case .cleanup15: 400
        case .cleanup66: 1_800
        case .cleanup236: 6_000
        }
    }

    var unit: String { [.meetingSearchMemory, .historySearchMemory10000].contains(self) ? "MB" : "ms" }
}

struct SpeedResult: Encodable {
    let row: SpeedRow
    let unit: String
    let budget: Double
    let runs: [Double]
    let median: Double?
    let low: Double?
    let high: Double?
    // Why the row was not measured, or why it failed though it was fast enough.
    let note: String?
    let passed: Bool

    init(_ row: SpeedRow, runs: [Double], failure: String? = nil) {
        let sorted = runs.sorted()
        self.row = row
        unit = row.unit
        budget = row.budget
        self.runs = runs
        median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        low = sorted.first
        high = sorted.last
        note = failure
        passed = failure == nil && (median ?? .infinity) <= row.budget
    }

    init(_ row: SpeedRow, skipped reason: String) {
        self.row = row
        unit = row.unit
        budget = row.budget
        runs = []
        median = nil
        low = nil
        high = nil
        note = "skipped: \(reason)"
        passed = true
    }
}

@MainActor
struct SpeedCheck {
    static let runs = 5

    let base: URL
    let now = Date()
    private(set) var results: [SpeedResult] = []

    static func milliseconds(_ work: @MainActor () async throws -> Void) async rethrows -> Double {
        let start = ContinuousClock.now
        try await work()
        return seconds(since: start) * 1000
    }

    static func timed(_ work: @MainActor () async throws -> Void) async rethrows -> [Double] {
        var values: [Double] = []
        for _ in 0..<runs { values.append(try await milliseconds(work)) }
        return values
    }

    static func progress(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // In a fresh process each time, because this one reuses the pages earlier rows let go of.
    static func searchMemory(_ root: URL, option: String = "--search-memory") throws -> Double {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["speed", option, root.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0, let megabytes = Double(printed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CocoaError(.executableLoad)
        }
        return megabytes
    }

    mutating func add(_ row: SpeedRow, _ runs: [Double]) {
        results.append(SpeedResult(row, runs: runs))
    }

    mutating func meetings() async throws {
        for (count, keystroke) in [(50, SpeedRow.meetingKeystroke50), (200, .meetingKeystroke200)] {
            Self.progress("writing \(count) one-hour meetings")
            let root = base.appending(path: "meetings-\(count)")
            let ids = try await SpeedData.meetings(count, in: root, now: now)
            let store = SpeedData.meetingStore(root)
            _ = try await MeetingSearch.hits(matching: SpeedText.miss, in: store)
            add(keystroke, try await Self.timed { _ = try await MeetingSearch.hits(matching: SpeedText.miss, in: store) })
            guard count == 200 else { continue }
            add(.meetingFirstSearch, try await Self.timed {
                _ = try await MeetingSearch.hits(matching: SpeedText.miss, in: SpeedData.meetingStore(root))
            })
            add(.meetingSearchMemory, try (0..<Self.runs).map { _ in try Self.searchMemory(root) })
            add(.meetingsFirstList, try await Self.timed { _ = try await SpeedData.meetingStore(root).list() })
            var afterChange: [Double] = []
            for _ in 0..<Self.runs {
                try await store.update(ids[0]) { $0.pinned.toggle() }
                afterChange.append(try await Self.milliseconds { _ = try await store.list() })
            }
            add(.meetingsListAfterChange, afterChange)
            add(.meetingOpen, try await Self.timed { _ = try await store.transcript(of: ids[0]) })
        }
    }

    mutating func history() async throws {
        let apps = AppDirectory(folders: [])
        let rows: [(Int, add: SpeedRow, search: SpeedRow, list: SpeedRow?)] = [
            (500, .historyAdd500, .historySearch500, nil),
            (2_000, .historyAdd2000, .historySearch2000, .historyFirstList2000),
            (10_000, .historyAdd10000, .historySearch10000, .historyFirstList10000)
        ]
        for (count, addRow, searchRow, listRow) in rows {
            Self.progress("writing \(count) dictations")
            let root = base.appending(path: "history-\(count)")
            try await SpeedData.history(count, in: root, now: now)
            if let listRow { add(listRow, try await Self.timed { _ = try await HistoryStore(root: root).entries() }) }
            let store = HistoryStore(root: root)
            let entries = try await store.entries().entries.filter(\.isFinished)
            var search = HistorySearch()
            _ = search.entries(entries, matching: SpeedText.found, apps: apps)
            add(searchRow, await Self.timed { _ = search.entries(entries, matching: SpeedText.found, apps: apps) })
            if count == 10_000 {
                add(.historyFirstSearch10000, await Self.timed { _ = HistorySearch.entries(entries, matching: SpeedText.found, apps: apps) })
                add(.historySearchMemory10000, try (0..<Self.runs).map { _ in try Self.searchMemory(root, option: "--history-search-memory") })
                add(.historyDays10000, await Self.timed { _ = HistoryDay.group(entries, now: now) })
            }
            // As a dictation writes it: its first line when it starts, its final line when it ends, then the list reads again.
            var index = count
            add(addRow, try await Self.timed {
                var entry = SpeedData.dictation(index, now: now)
                index += 1
                entry.startedAt = Date()
                entry.outcome = nil
                try await store.append(entry)
                entry.outcome = .pasted
                try await store.append(entry)
                _ = try await store.entries()
            })
        }
    }

    // The default model only, and only if it is already on this Mac; this never downloads.
    mutating func cleanup(models: ModelStore) async throws {
        let cleanupRows = [SpeedRow.cleanupLoad, .cleanup15, .cleanup66, .cleanup236]
        let engine = LocalModelEngine(model: ModelReference(CleanupSettings.localModel.defaultValue), store: models)
        guard (try? engine.bytesOnDisk()) ?? 0 > 0 else {
            results += cleanupRows.map { SpeedResult($0, skipped: "model not downloaded") }
            return
        }
        Self.progress("timing the clean-up model")
        let suite = "narrari-speed-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.featureUnsupported) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CleanupService(engine: engine, settings: SettingsStore(defaults: defaults))
        var loads: [Double] = []
        for _ in 0..<Self.runs {
            await engine.unload()
            loads.append(try await Self.milliseconds { try await engine.load() })
        }
        add(.cleanupLoad, loads)
        _ = await service.clean(SpeedText.sentence(10, seed: 0), with: .tidy)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../fixtures/cleanup-lengths.json")
        let samples = try JSONDecoder().decode([LengthSample].self, from: Data(contentsOf: fixture))
        for (id, row) in [("short", SpeedRow.cleanup15), ("medium", .cleanup66), ("long", .cleanup236)] {
            guard let sample = samples.first(where: { $0.id == id }) else { throw CocoaError(.fileReadCorruptFile) }
            var reasons: Set<String> = []
            let runs = await Self.timed {
                let result = await service.clean(sample.text, with: .tidy)
                if result.status != .cleaned { reasons.insert(result.reason?.rawValue ?? result.status.rawValue) }
            }
            results.append(SpeedResult(row, runs: runs, failure: reasons.isEmpty ? nil : "not cleaned: " + reasons.sorted().joined(separator: ", ")))
        }
        await engine.unload()
    }
}

#if DEBUG
let isReleaseBuild = false
#else
let isReleaseBuild = true
#endif

// Synthetic data in a temporary folder on a release build; false when a row misses its budget.
@MainActor
func speed(json: Bool, models: ModelStore) async throws -> Bool {
    guard isReleaseBuild else {
        SpeedCheck.progress("measure a release build: swift build -c release --product narrari-dev && .build/release/narrari-dev speed")
        exit(2)
    }
    let base = FileManager.default.temporaryDirectory.appending(path: "narrari-speed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    var check = SpeedCheck(base: base)
    try await check.meetings()
    try await check.history()
    try await check.cleanup(models: models)
    let results = check.results.sorted { SpeedRow.allCases.firstIndex(of: $0.row) ?? 0 < SpeedRow.allCases.firstIndex(of: $1.row) ?? 0 }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(bytes: try encoder.encode(results), encoding: .utf8) ?? "")
    } else {
        printSpeedTable(results)
    }
    return results.allSatisfy(\.passed)
}

// What the meeting search keeps in memory after its first search, printed in MB for the parent speed run.
@MainActor
func printSearchMemory(_ folder: String) async throws {
    let before = memoryMegabytes().footprint
    let store = SpeedData.meetingStore(URL(filePath: folder))
    _ = try await MeetingSearch.hits(matching: SpeedText.miss, in: store)
    print(withExtendedLifetime(store) { memoryMegabytes().footprint - before })
}

// What the dictation search keeps in memory after its first search, beyond the dictations the list holds anyway.
@MainActor
func printHistorySearchMemory(_ folder: String) async throws {
    let entries = try await HistoryStore(root: URL(filePath: folder)).entries().entries.filter(\.isFinished)
    let before = memoryMegabytes().footprint
    var search = HistorySearch()
    _ = search.entries(entries, matching: SpeedText.found, apps: AppDirectory(folders: []))
    print(withExtendedLifetime((entries, search)) { memoryMegabytes().footprint - before })
}

func printSpeedTable(_ results: [SpeedResult]) {
    let width = SpeedRow.allCases.map(\.rawValue.count).max() ?? 0
    func number(_ value: Double?, _ unit: String) -> String {
        guard let value else { return "" }
        return String(format: value < 10 ? "%.2f %@" : "%.0f %@", value, unit)
    }
    print("row".padding(toLength: width, withPad: " ", startingAt: 0) + " | median | min to max | budget | result")
    for result in results {
        let spread = result.low.map { "\(number($0, result.unit)) to \(number(result.high, result.unit))" } ?? ""
        let verdict = result.median == nil ? "" : result.passed ? "pass" : "FAIL"
        print([
            result.row.rawValue.padding(toLength: width, withPad: " ", startingAt: 0), number(result.median, result.unit), spread,
            number(result.budget, result.unit), [verdict, result.note ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
        ].joined(separator: " | "))
    }
}
