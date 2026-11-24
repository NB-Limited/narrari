import Foundation
import NarrariKit
import Testing

struct DoctorFactsTests {
    private func line(_ time: String, _ message: String) -> String {
        #"{"timestamp":"2026-11-20 \#(time).945788+0100","processID":4894,"eventMessage":"\#(message)","subsystem":"com.nb-limited.narrari"}"#
    }

    @Test func doctor_reads_the_newest_permission_report_from_the_log() {
        let log = [
            line("09:00:00", "event permission-microphone-not-asked"),
            line("09:00:00", "event permission-accessibility-off"),
            line("09:05:12", "event permission-microphone-allowed"),
            line("09:05:12", "event shortcut-tap-refused"),
            line("09:06:30", "event shortcut-tap-on"),
            line("09:06:31", "event shortcut-tap-reenabled-timeout"),
            #"{"count":3,"finished":1}"#
        ].joined(separator: "\n")

        let reports = DoctorFacts.appReports(inLog: Data(log.utf8))

        #expect(reports.microphone?.value == .allowed)
        #expect(reports.microphone?.at == "2026-11-20 09:05:12")
        #expect(reports.accessibility?.value == false)
        #expect(reports.accessibility?.at == "2026-11-20 09:00:00")
        #expect(reports.shortcutTap?.value == .working)
        #expect(reports.shortcutTap?.at == "2026-11-20 09:06:30")
    }
}
