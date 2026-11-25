import Foundation

// A company directory lists people surname first with initials, "Novak,Milena M.M." or "Berg, Stijn S. van den"; the
// same person reads "Milena Novak" and "Stijn van den Berg" everywhere, so one person is never listed two ways.
public enum PersonName {
    public static func plain(_ name: String) -> String {
        let parts = name.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty else { return name }
        let given = parts[1].split(separator: " ").filter { !isInitials($0) }
        // Without a given name in full it is not this form, such as a company's "Acme, Inc."
        guard given.contains(where: { !$0.contains(".") }) else { return name }
        return (given.map(String.init) + [parts[0]]).joined(separator: " ")
    }

    private static func isInitials(_ word: Substring) -> Bool {
        word.hasSuffix(".") && word.split(separator: ".").allSatisfy { $0.count == 1 }
    }
}
