import ApplicationServices
import Cocoa

class ClipboardService {
    static let shared = ClipboardService()

    struct ClipboardSnapshot {
        fileprivate let items: [ClipboardItemSnapshot]
    }

    fileprivate struct ClipboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    // Dependency injection for license checking
    private var licenseManager: LicenseManager {
        return LicenseManager.shared
    }

    private init() {}

    // Copy text to system clipboard with optional promotional wrapper
    func copy(text: String) {
        let finalText = wrapTextIfNeeded(text)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalText, forType: .string)

        // Verify write
        if let check = pasteboard.string(forType: .string), check == finalText {
            print("✅ Clipboard Write Verified: '\(check.prefix(20))...'")
        } else {
            print("❌ Clipboard Write FAILED!")
        }
    }

    @discardableResult
    func copyForTemporaryPaste(text: String) -> ClipboardSnapshot {
        let snapshot = currentSnapshot()
        copy(text: text)
        return snapshot
    }

    func restore(_ snapshot: ClipboardSnapshot, ifCurrentStringMatches expectedText: String) {
        let pasteboard = NSPasteboard.general
        let expectedFinalText = wrapTextIfNeeded(expectedText)

        guard pasteboard.string(forType: .string) == expectedFinalText else {
            print("Skipping clipboard restore because pasteboard changed after paste")
            return
        }

        restore(snapshot)
    }

    // Wrap text with promotional message for free users
    private func wrapTextIfNeeded(_ text: String) -> String {
        // License check disabled - always allow unwrapped text
        return text
    }

    private func currentSnapshot() -> ClipboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items: [ClipboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]

            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }

            return ClipboardItemSnapshot(dataByType: dataByType)
        } ?? []

        return ClipboardSnapshot(items: items)
    }

    private func restore(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            print("Restored empty clipboard")
            return
        }

        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshotItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
        print("Restored previous clipboard contents")
    }

    /// Posts Cmd+V synchronously after the target application has been
    /// reactivated. Returning an explicit result makes a paste failure visible
    /// to the caller instead of silently looking like a transcription issue.
    @discardableResult
    func paste() -> Bool {
        guard isAccessibilityTrusted else {
            print("Auto-paste skipped: Accessibility permission is not granted")
            return false
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            print("Auto-paste failed: could not create keyboard events")
            return false
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        print("Auto-paste: Cmd+V posted")
        return true
    }

    // Fallback using AppleScript (more robust for some apps)
    func appleScriptPaste() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript Paste Error: \(error)")
            } else {
                print("Executed AppleScript Paste")
            }
        }
    }

    // Check if we have permission to send keystrokes
    var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    // Request permission via system prompt
    func requestAccessibilityPermission() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
