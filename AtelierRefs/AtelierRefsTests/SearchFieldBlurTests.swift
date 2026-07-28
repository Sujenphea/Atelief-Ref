//
//  SearchFieldBlurTests.swift
//  AtelierRefsTests
//
//  `LibrarySearchable` wraps every pane and blurs the search field on a tap anywhere
//  in the content (URL-bar behaviour). Which responders that is allowed to blur is
//  the whole of this file, because getting it wrong broke inline text editing on the
//  canvas in a way that looked nothing like a search bug: the guard read
//  `responder is NSText`, `NSTextView` is a subclass of `NSText`, and a
//  `simultaneousGesture` ends on mouse-UP — so every double-click that opened a text
//  box was blurred milliseconds later by the search field's own dismiss handler.
//

import AppKit
import Testing
@testable import AtelierRefs

@MainActor
@Suite("A content tap blurs the search field and nothing else")
struct SearchFieldBlurTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
    }

    @Test("the window's field editor — what a focused text field uses — is blurred")
    func fieldEditorIsBlurred() {
        let window = makeWindow()
        // The shared per-window editor an NSTextField (and so a SwiftUI TextField)
        // borrows while focused. This is the search field's responder.
        let fieldEditor = try? #require(window.fieldEditor(true, for: nil))
        #expect(fieldEditor?.isFieldEditor == true)
        #expect(isSearchFieldEditor(fieldEditor))
    }

    @Test("a standalone NSTextView is NOT blurred — this is the canvas's inline editor")
    func standaloneTextViewIsLeftAlone() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        // The distinction the old `is NSText` check missed. A text view the app owns
        // outright is not a field editor, however much it looks like one.
        let responder: NSResponder = textView
        #expect(responder is NSText)         // …which is exactly why the old guard fired
        #expect(textView.isFieldEditor == false)
        #expect(!isSearchFieldEditor(textView))
    }

    @Test("nothing focused, or a plain view focused, blurs nothing")
    func otherRespondersAreLeftAlone() {
        #expect(!isSearchFieldEditor(nil))
        #expect(!isSearchFieldEditor(NSView(frame: .zero)))
        #expect(!isSearchFieldEditor(makeWindow()))
        #expect(!isSearchFieldEditor(NSButton(frame: .zero)))
    }
}
