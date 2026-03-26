import AppKit
import CAwalTerminal

// MARK: - Keyboard Input

extension TerminalView {

    override func keyDown(with event: NSEvent) {
        switch appState {
        case .menu:
            handleMenuKey(event)
        case .terminal:
            handleTerminalKey(event)
        }
    }

    func handleMenuKey(_ event: NSEvent) {
        // Handle delete confirmation mode
        if pendingDeleteIndex != nil {
            if let chars = event.characters, chars == "y" {
                // Confirm deletion
                if let idx = pendingDeleteIndex, idx < menuEntries.count,
                   case .recentWorkspace(let ws) = menuEntries[idx] {
                    WorkspaceStore.shared.remove(path: ws.path, model: ws.lastModel)
                    pendingDeleteIndex = nil
                    buildMenuEntries()
                    // Adjust selection if it's now out of bounds
                    if menuSelection >= menuEntries.count {
                        menuSelection = max(0, menuEntries.count - 1)
                    }
                    if !menuEntries.isEmpty && !isSelectable(menuEntries[menuSelection]) {
                        moveToFirstSelectable()
                    }
                }
            } else {
                // Any other key cancels
                pendingDeleteIndex = nil
            }
            renderMenu()
            return
        }

        switch event.keyCode {
        case 126: // Up arrow
            moveSelection(by: -1)
            renderMenu()
        case 125: // Down arrow
            moveSelection(by: 1)
            renderMenu()
        case 36: // Return
            handleSelection()
        case 51: // Backspace / Delete
            if case .main = menuPhase,
               menuSelection < menuEntries.count,
               case .recentWorkspace = menuEntries[menuSelection] {
                pendingDeleteIndex = menuSelection
                renderMenu()
            }
        case 53: // Escape
            switch menuPhase {
            case .main:
                // Launch Shell directly
                let shellItem = modelItems.last!
                launchSession(model: shellItem, workingDir: nil)
            case .pickModel, .pickFolder, .resumeSessions:
                // Go back to main menu
                menuPhase = .main
                buildMenuEntries()
                moveToFirstSelectable()
                renderMenu()
            }
        default:
            if let chars = event.characters {
                switch chars {
                case "j":
                    moveSelection(by: 1)
                    renderMenu()
                case "k":
                    moveSelection(by: -1)
                    renderMenu()
                case "d":
                    if case .main = menuPhase,
                       menuSelection < menuEntries.count,
                       case .restoreSession = menuEntries[menuSelection] {
                        WindowStateStore.deleteSavedState()
                        buildMenuEntries()
                        if menuSelection >= menuEntries.count {
                            menuSelection = max(0, menuEntries.count - 1)
                        }
                        if !menuEntries.isEmpty && !isSelectable(menuEntries[menuSelection]) {
                            moveToFirstSelectable()
                        }
                        renderMenu()
                    }
                case "o":
                    switch menuPhase {
                    case .main, .pickFolder:
                        showFolderPicker()
                    default:
                        break
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Kitty Keyboard Protocol helpers

    /// Map macOS keyCode to Kitty keyboard protocol unicode key number.
    /// Returns (key_number, is_functional_key).
    static func kittyKeyNumber(for keyCode: UInt16, chars: String) -> (UInt32, Bool) {
        switch keyCode {
        case 53:  return (27, true)     // Escape
        case 36:  return (13, true)     // Return
        case 48:  return (9, true)      // Tab
        case 51:  return (127, true)    // Backspace
        case 117: return (57355, true)  // Delete (forward)
        case 123: return (57419, true)  // Left
        case 124: return (57421, true)  // Right
        case 125: return (57420, true)  // Down
        case 126: return (57418, true)  // Up
        case 115: return (57423, true)  // Home
        case 119: return (57424, true)  // End
        case 116: return (57425, true)  // PageUp
        case 121: return (57426, true)  // PageDown
        case 114: return (57427, true)  // Insert
        // Function keys
        case 122: return (57364, true)  // F1
        case 120: return (57365, true)  // F2
        case 99:  return (57366, true)  // F3
        case 118: return (57367, true)  // F4
        case 96:  return (57368, true)  // F5
        case 97:  return (57369, true)  // F6
        case 98:  return (57370, true)  // F7
        case 100: return (57371, true)  // F8
        case 101: return (57372, true)  // F9
        case 109: return (57373, true)  // F10
        case 103: return (57374, true)  // F11
        case 111: return (57375, true)  // F12
        // Numpad keys
        case 82: return (57399, true)  // KP_0
        case 83: return (57400, true)  // KP_1
        case 84: return (57401, true)  // KP_2
        case 85: return (57402, true)  // KP_3
        case 86: return (57403, true)  // KP_4
        case 87: return (57404, true)  // KP_5
        case 88: return (57405, true)  // KP_6
        case 89: return (57406, true)  // KP_7
        case 91: return (57407, true)  // KP_8
        case 92: return (57408, true)  // KP_9
        case 65: return (57409, true)  // KP_Decimal
        case 75: return (57410, true)  // KP_Divide
        case 67: return (57411, true)  // KP_Multiply
        case 69: return (57412, true)  // KP_Add
        case 78: return (57413, true)  // KP_Subtract
        case 81: return (57414, true)  // KP_Equal
        case 76: return (57415, true)  // KP_Enter
        default:
            // For regular characters, use the Unicode codepoint
            if let scalar = chars.unicodeScalars.first {
                return (scalar.value, false)
            }
            return (0, false)
        }
    }

    /// Map functional keys to their legacy CSI sequences for kitty protocol.
    /// Functional keys (arrows, home/end, function keys, etc.) must use their
    /// legacy encoding — NOT the generic CSI <number> u format.
    static func kittyFunctionalKeySequence(keyCode: UInt16, modParam: UInt32) -> [UInt8]? {
        let hasMod = modParam > 1

        let seq: String
        switch keyCode {
        // Arrow keys: CSI 1;mod <letter> (with mod) or CSI <letter> (without)
        case 126: seq = hasMod ? "\u{1b}[1;\(modParam)A" : "\u{1b}[A"   // Up
        case 125: seq = hasMod ? "\u{1b}[1;\(modParam)B" : "\u{1b}[B"   // Down
        case 124: seq = hasMod ? "\u{1b}[1;\(modParam)C" : "\u{1b}[C"   // Right
        case 123: seq = hasMod ? "\u{1b}[1;\(modParam)D" : "\u{1b}[D"   // Left
        // Home/End: CSI 1;mod H/F (with mod) or CSI H/F (without)
        case 115: seq = hasMod ? "\u{1b}[1;\(modParam)H" : "\u{1b}[H"   // Home
        case 119: seq = hasMod ? "\u{1b}[1;\(modParam)F" : "\u{1b}[F"   // End
        // Tilde keys: CSI number;mod ~ (with mod) or CSI number ~ (without)
        case 117: seq = hasMod ? "\u{1b}[3;\(modParam)~" : "\u{1b}[3~"   // Forward Delete
        case 116: seq = hasMod ? "\u{1b}[5;\(modParam)~" : "\u{1b}[5~"   // PageUp
        case 121: seq = hasMod ? "\u{1b}[6;\(modParam)~" : "\u{1b}[6~"   // PageDown
        case 114: seq = hasMod ? "\u{1b}[2;\(modParam)~" : "\u{1b}[2~"   // Insert
        // F1-F4: CSI 1;mod P/Q/R/S (or SS3 without modifiers)
        case 122: seq = modParam > 1 ? "\u{1b}[1;\(modParam)P" : "\u{1b}OP"  // F1
        case 120: seq = modParam > 1 ? "\u{1b}[1;\(modParam)Q" : "\u{1b}OQ"  // F2
        case 99:  seq = modParam > 1 ? "\u{1b}[1;\(modParam)R" : "\u{1b}OR"  // F3
        case 118: seq = modParam > 1 ? "\u{1b}[1;\(modParam)S" : "\u{1b}OS"  // F4
        // F5-F12: CSI number;mod ~ (with mod) or CSI number ~ (without)
        case 96:  seq = hasMod ? "\u{1b}[15;\(modParam)~" : "\u{1b}[15~"  // F5
        case 97:  seq = hasMod ? "\u{1b}[17;\(modParam)~" : "\u{1b}[17~"  // F6
        case 98:  seq = hasMod ? "\u{1b}[18;\(modParam)~" : "\u{1b}[18~"  // F7
        case 100: seq = hasMod ? "\u{1b}[19;\(modParam)~" : "\u{1b}[19~"  // F8
        case 101: seq = hasMod ? "\u{1b}[20;\(modParam)~" : "\u{1b}[20~"  // F9
        case 109: seq = hasMod ? "\u{1b}[21;\(modParam)~" : "\u{1b}[21~"  // F10
        case 103: seq = hasMod ? "\u{1b}[23;\(modParam)~" : "\u{1b}[23~"  // F11
        case 111: seq = hasMod ? "\u{1b}[24;\(modParam)~" : "\u{1b}[24~"  // F12
        // Escape, Return, Tab, Backspace — use CSI u format (no legacy override)
        default: return nil
        }

        return Array(seq.utf8)
    }

    /// Encode a key event using the Kitty keyboard protocol (CSI u format).
    func encodeKittyKey(_ event: NSEvent, flags kittyFlags: UInt32) -> [UInt8]? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        let unmodChars = event.charactersIgnoringModifiers ?? chars

        let modFlags = event.modifierFlags
        let hasShift = modFlags.contains(.shift)
        let hasAlt = modFlags.contains(.option)
        let hasCtrl = modFlags.contains(.control)

        // Kitty modifier encoding: shift=1, alt=2, ctrl=4, super=8
        var modBits: UInt32 = 0
        if hasShift { modBits |= 1 }
        if hasAlt { modBits |= 2 }
        if hasCtrl { modBits |= 4 }
        let modParam = modBits + 1  // 1-based (1 = no modifiers)

        let (keyNum, isFunctional) = Self.kittyKeyNumber(for: event.keyCode, chars: unmodChars)
        guard keyNum != 0 else { return nil }

        let disambiguate = (kittyFlags & 1) != 0
        let reportAllKeys = (kittyFlags & 8) != 0

        // Only use CSI u for keys that need it
        let needsCSIu: Bool
        if isFunctional || modParam > 1 {
            needsCSIu = true
        } else if reportAllKeys {
            needsCSIu = true
        } else if disambiguate {
            // Disambiguate mode: only encode keys that are ambiguous in legacy encoding.
            // Plain printable characters without modifiers are unambiguous — pass through as UTF-8.
            needsCSIu = isFunctional || keyNum == 27 || keyNum == 13 || keyNum == 9 || keyNum == 127
        } else {
            needsCSIu = false
        }

        guard needsCSIu else { return nil }

        // Functional keys must use their legacy CSI sequences per kitty spec,
        // NOT the generic CSI <number> u format.
        if isFunctional, let legacySeq = Self.kittyFunctionalKeySequence(keyCode: event.keyCode, modParam: modParam) {
            return legacySeq
        }

        // Regular keys use CSI <key> ; <modifiers> u
        var seq: String
        if modParam > 1 {
            seq = "\u{1b}[\(keyNum);\(modParam)u"
        } else {
            seq = "\u{1b}[\(keyNum)u"
        }

        return Array(seq.utf8)
    }

    func handleTerminalKey(_ event: NSEvent) {
        guard let s = surface else { return }

        let modFlags = event.modifierFlags

        // Let Cmd-key combos through to the menu system (Cmd+,  Cmd+Q  etc.)
        if modFlags.contains(.command) { return }

        let bytes: [UInt8]

        // Check if kitty keyboard protocol is active
        let kittyFlags = at_surface_get_kitty_keyboard_flags(s)
        if kittyFlags > 0, let kittyBytes = encodeKittyKey(event, flags: kittyFlags) {
            bytes = kittyBytes
        } else if let chars = event.characters, !chars.isEmpty {
            let hasShift = modFlags.contains(.shift)
            let hasCtrl = modFlags.contains(.control)
            let hasAlt = modFlags.contains(.option)

            // xterm modifier parameter: 1=none, 2=Shift, 3=Alt, 5=Ctrl, etc.
            var modParam = 1
            if hasShift { modParam += 1 }
            if hasAlt { modParam += 2 }
            if hasCtrl { modParam += 4 }
            let hasMod = modParam > 1

            switch event.keyCode {
            case 36: // Return
                hideCompletions()
                bytes = [0x0D]
            case 48: // Tab
                if !hasShift, let popup = completionPopup, popup.isVisible {
                    popup.acceptSelected()
                    return
                }
                bytes = hasShift ? [0x1B, 0x5B, 0x5A] : [0x09]
            case 51: // Backspace
                bytes = [0x7F]
            case 53: // Escape
                if let popup = completionPopup, popup.isVisible {
                    hideCompletions()
                    return
                }
                bytes = [0x1B]
            case 123: // Left
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)D".utf8) : [0x1B, 0x5B, 0x44]
            case 124: // Right
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)C".utf8) : [0x1B, 0x5B, 0x43]
            case 125: // Down
                if !hasMod, let popup = completionPopup, popup.isVisible {
                    popup.selectNext()
                    return
                }
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)B".utf8) : [0x1B, 0x5B, 0x42]
            case 126: // Up
                if !hasMod, let popup = completionPopup, popup.isVisible {
                    popup.selectPrevious()
                    return
                }
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)A".utf8) : [0x1B, 0x5B, 0x41]
            case 115: // Home
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)H".utf8) : [0x1B, 0x5B, 0x48]
            case 119: // End
                bytes = hasMod ? Array("\u{1b}[1;\(modParam)F".utf8) : [0x1B, 0x5B, 0x46]
            case 116: // PageUp
                bytes = hasMod ? Array("\u{1b}[5;\(modParam)~".utf8) : [0x1B, 0x5B, 0x35, 0x7E]
            case 121: // PageDown
                bytes = hasMod ? Array("\u{1b}[6;\(modParam)~".utf8) : [0x1B, 0x5B, 0x36, 0x7E]
            case 117: // Forward Delete
                bytes = hasMod ? Array("\u{1b}[3;\(modParam)~".utf8) : [0x1B, 0x5B, 0x33, 0x7E]
            // Function keys F1-F12
            case 122: bytes = hasMod ? Array("\u{1b}[1;\(modParam)P".utf8) : [0x1B, 0x4F, 0x50]
            case 120: bytes = hasMod ? Array("\u{1b}[1;\(modParam)Q".utf8) : [0x1B, 0x4F, 0x51]
            case 99:  bytes = hasMod ? Array("\u{1b}[1;\(modParam)R".utf8) : [0x1B, 0x4F, 0x52]
            case 118: bytes = hasMod ? Array("\u{1b}[1;\(modParam)S".utf8) : [0x1B, 0x4F, 0x53]
            case 96:  bytes = Array("\u{1b}[15\(hasMod ? ";\(modParam)" : "")~".utf8)  // F5
            case 97:  bytes = Array("\u{1b}[17\(hasMod ? ";\(modParam)" : "")~".utf8)  // F6
            case 98:  bytes = Array("\u{1b}[18\(hasMod ? ";\(modParam)" : "")~".utf8)  // F7
            case 100: bytes = Array("\u{1b}[19\(hasMod ? ";\(modParam)" : "")~".utf8)  // F8
            case 101: bytes = Array("\u{1b}[20\(hasMod ? ";\(modParam)" : "")~".utf8)  // F9
            case 109: bytes = Array("\u{1b}[21\(hasMod ? ";\(modParam)" : "")~".utf8)  // F10
            case 103: bytes = Array("\u{1b}[23\(hasMod ? ";\(modParam)" : "")~".utf8)  // F11
            case 111: bytes = Array("\u{1b}[24\(hasMod ? ";\(modParam)" : "")~".utf8)  // F12
            default:
                if hasCtrl {
                    if let firstChar = chars.unicodeScalars.first {
                        let value = firstChar.value
                        if value >= 0x61 && value <= 0x7A {
                            bytes = [UInt8(value - 0x60)]
                        } else if value >= 0x41 && value <= 0x5A {
                            bytes = [UInt8(value - 0x40)]
                        } else {
                            bytes = Array(chars.utf8)
                        }
                    } else {
                        return
                    }
                } else if hasAlt {
                    let charBytes = Array(chars.utf8)
                    bytes = [0x1B] + charBytes
                } else {
                    bytes = Array(chars.utf8)
                }
            }
        } else {
            return
        }

        bytes.withUnsafeBufferPointer { ptr in
            _ = at_surface_key_event(s, ptr.baseAddress!, UInt32(ptr.count))
        }

        // Trigger autocomplete after key input
        scheduleCompletionUpdate()
    }

    override func flagsChanged(with event: NSEvent) {}
}
