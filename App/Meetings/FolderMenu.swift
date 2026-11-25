import AppKit
import NarrariKit

// Move to folder, from the page's toolbar or a row's menu: the folders with the current one checked, then a new one by name.
@MainActor
enum FolderMenu {
    static func open(_ id: UUID, in library: MeetingLibrary, from view: NSView) {
        let current = library.entries.first { $0.id == .meeting(id) }?.folder
        let folders = library.folders
        let rows = folders.map { DropdownRow(title: $0) } + [DropdownRow(title: "New folder…")]
        Dropdown.shared.open(
            label: "Move to folder", rows: rows, chosen: folders.firstIndex { $0 == current }, from: view, alignment: .trailing
        ) { index in
            guard folders.indices.contains(index) else { return newFolder(id, in: library, from: view) }
            Task { await library.move(id, toFolder: folders[index]) }
        }
    }

    private static func newFolder(_ id: UUID, in library: MeetingLibrary, from view: NSView) {
        let field = DropdownField(placeholder: "Folder name") { typed in
            let name = typed.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return [] }
            return [DropdownRow(title: "Move to “\(name)”", action: { Task { await library.move(id, toFolder: name) } })]
        }
        Task { @MainActor in Dropdown.shared.open(label: "New folder", field: field, from: view, alignment: .trailing) }
    }
}
