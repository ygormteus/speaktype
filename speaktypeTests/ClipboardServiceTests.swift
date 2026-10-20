import XCTest
import Cocoa
@testable import speaktype

final class ClipboardServiceTests: XCTestCase {
    func testPasteUsesSessionEventsWithoutPostingToHardwareInput() {
        var posted: [(CGEvent, CGEventTapLocation)] = []
        let service = ClipboardService(accessibilityCheck: { true }, eventPoster: { event, location in
            posted.append((event, location))
        })

        XCTAssertTrue(service.paste())
        XCTAssertEqual(posted.count, 4)
        XCTAssertTrue(posted.allSatisfy { $0.1 == .cgSessionEventTap })
        XCTAssertEqual(posted.map { $0.0.getIntegerValueField(.eventSourceStateID) }, Array(repeating: Int64(CGEventSourceStateID.combinedSessionState.rawValue), count: 4))
        XCTAssertEqual(posted.map { $0.0.getIntegerValueField(.keyboardEventKeycode) }, [0x37, 0x09, 0x09, 0x37])
        XCTAssertEqual(posted.map { $0.0.type }, [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(posted.map { $0.0.flags }, [.maskCommand, .maskCommand, .maskCommand, []])
    }

    func testDeniedPasteNeverPostsKeyboardEvents() {
        var postedCount = 0
        let service = ClipboardService(accessibilityCheck: { false }, eventPoster: { _, _ in postedCount += 1 })
        XCTAssertFalse(service.paste())
        XCTAssertEqual(postedCount, 0)
    }

    func testDeniedAutoPasteKeepsTranscriptWhenRestoreIsEnabled() {
        let service = ClipboardService(accessibilityCheck: { false })
        service.copy(text: "Original clipboard")

        let preparation = service.prepareAutoPaste(text: "Texto ditado", restoreClipboard: true)

        guard case .requiresAccessibility = preparation else {
            return XCTFail("Denied permission must require user action")
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Texto ditado")
        XCTAssertFalse(service.paste())
    }

    func testAllowedAutoPastePreservesSnapshotWhenRequested() {
        let service = ClipboardService(accessibilityCheck: { true })
        service.copy(text: "Original clipboard")

        let preparation = service.prepareAutoPaste(text: "Texto ditado", restoreClipboard: true)

        guard case .ready(let snapshot?) = preparation else {
            return XCTFail("Allowed permission must prepare a clipboard snapshot")
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Texto ditado")
        service.restore(snapshot, ifCurrentStringMatches: "Texto ditado")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Original clipboard")
    }

    func testAllowedAutoPasteWithoutRestoreKeepsTranscript() {
        let service = ClipboardService(accessibilityCheck: { true })

        let preparation = service.prepareAutoPaste(text: "Texto ditado", restoreClipboard: false)

        guard case .ready(nil) = preparation else {
            return XCTFail("Clipboard restoration must remain optional")
        }
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Texto ditado")
    }
    
    func testCopy() {
        let text = "Copied Text Check"
        ClipboardService.shared.copy(text: text)
        
        let pasteboard = NSPasteboard.general
        let copied = pasteboard.string(forType: .string)
        
        XCTAssertEqual(copied, text, "Clipboard content should match copied text")
    }

    func testTemporaryPasteCanRestorePreviousClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://example.com/original", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated text")

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/original")
    }

    func testRestoreDoesNotOverwriteClipboardChangedAfterPaste() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard", forType: .string)

        let snapshot = ClipboardService.shared.copyForTemporaryPaste(text: "Dictated text")
        pasteboard.clearContents()
        pasteboard.setString("User copied something else", forType: .string)

        ClipboardService.shared.restore(snapshot, ifCurrentStringMatches: "Dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "User copied something else")
    }
    
}
