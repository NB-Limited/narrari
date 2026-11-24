import Carbon.HIToolbox

// A shortcut typed in a terminal, such as ctrl+opt+m or ⌃⌥M, read through the names HotkeyName prints.
enum ShortcutText {
    private static let modifierWords = [
        "ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"
    ]

    private static let symbolWords = ["⌃": "ctrl", "⌥": "opt", "⇧": "shift", "⌘": "cmd"]

    private static let keyWords = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
        "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "escape": kVK_Escape, "esc": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home,
        "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown
    ]

    // A modifier word may name the right-hand key, as in right-cmd+m; symbols and plain words work from either side.
    @MainActor
    static func shortcut(_ text: String) -> Shortcut? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let symbols = Set(Shortcut.flags.map(\.symbol))
        var modifiers: [String: Bool] = [:]
        var key = parts.last ?? ""
        if parts.count > 1 {
            for part in parts.dropLast() {
                let word = part.lowercased()
                let isRight = word.hasPrefix("right-") || word.hasPrefix("right ")
                let name = isRight ? String(word.dropFirst(6)) : word
                guard let symbol = modifierWords[name] ?? (symbols.contains(part) ? part : nil) else { return nil }
                modifiers[symbol] = isRight
            }
        } else {
            let lead = key.prefix { symbols.contains(String($0)) }
            lead.forEach { modifiers[String($0)] = false }
            key = String(key.dropFirst(lead.count))
        }
        guard !key.isEmpty, let code = keyCode(named: key) else { return nil }
        let mask = Shortcut.flags.reduce(0) { mask, flag in
            modifiers[flag.symbol].map { mask | Shortcut.mask(flag.carbon, isRightOnly: $0) } ?? mask
        }
        return Shortcut(keyCode: code, modifiers: mask)
    }

    static func modifierKey(_ text: String) -> Int? {
        let wanted = plain(text)
        return ModifierKey.supportedKeyCodes.first { ModifierKey(keyCode: $0).map { plain($0.name) } == wanted }
    }

    static var modifierKeyNames: String {
        ModifierKey.supportedKeyCodes.compactMap { ModifierKey(keyCode: $0).map { plain($0.name) } }.joined(separator: ", ")
    }

    // In alphabet and digit order, for a Latin letter typed while a layout such as Bulgarian is in use.
    private static let latinKeys = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z
    ]
    private static let digitKeys = [
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    // The first key code on this keyboard layout with the name, so a digit is the top row's, not the keypad's.
    @MainActor
    private static func keyCode(named name: String) -> Int? {
        if let code = keyWords[name.lowercased()] { return code }
        if let code = (0..<128).first(where: { HotkeyName.keyName($0).uppercased() == name.uppercased() }) { return code }
        guard name.count == 1, let character = name.uppercased().unicodeScalars.first, character.isASCII else { return nil }
        let value = Int(character.value)
        switch value {
        case 65...90: return latinKeys[value - 65]
        case 48...57: return digitKeys[value - 48]
        default: return nil
        }
    }

    private static func plain(_ text: String) -> String {
        text.lowercased().split { $0 == " " || $0 == "-" || $0 == "_" }.map { word in
            let symbol = modifierWords[String(word)] ?? String(word)
            return symbolWords[symbol] ?? symbol
        }
        .joined(separator: "-")
    }
}
