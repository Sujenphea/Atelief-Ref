# 271 — The search field's dismiss handler was closing the canvas editor

## Summary

Double-click-to-edit was reported broken "99% of the time" after 266, 268 and 269. It
was never broken. Instrumenting the real app showed the editor opening on **every**
double-click, taking first responder successfully, and then being torn down 5–60 ms
later with no mouse event in between:

```
press clicks=2 … target=activate(tileID: 17)
beginEditing tile=17 new=false
takeFirstResponder tile=17 ok=true now=CanvasEditorTextView
BLUR tile=17 inWindow=true superview=true          ← 50 ms later, unprompted
editDidFinish tile=17 outcome=committed(…)
```

A call stack captured at the blur named the culprit outright:

```
-[NSTextView resignFirstResponder]
-[NSWindow _realMakeFirstResponder:]
AtelierRefs.LibrarySearchable.body … simultaneousGesture … _EndedGesture<TapGesture>
```

`LibrarySearchable` wraps every pane, the Space included, and implements URL-bar
behaviour — click anywhere in the content and the search field blurs:

```swift
.simultaneousGesture(TapGesture().onEnded {
    if let window = NSApp.keyWindow, window.firstResponder is NSText {
        window.makeFirstResponder(nil)
    }
    search.clearSuggestions()
})
```

The guard was meant to catch only the search field's editor — the comment beside it said
so. But **`NSTextView` is a subclass of `NSText`**, so it also matched the canvas's
inline text editor. A `simultaneousGesture` runs alongside the canvas's own mouse
handling and ends on mouse-**UP**, which is *after* `mouseDown` created the editor. So
the search field's dismiss handler closed the text box on the very click that opened it.

## The fix

Ask the question the guard was actually reaching for. A *field editor* is the shared
per-window `NSTextView` that an `NSTextField` — and so a SwiftUI `TextField` — borrows
while focused. The canvas owns its text view outright, so it is not one:

```swift
func isSearchFieldEditor(_ responder: NSResponder?) -> Bool {
    guard let text = responder as? NSText else { return false }
    return text.isFieldEditor
}
```

Verified rather than assumed: a focused SwiftUI `TextField` resolves to an `NSText` with
`isFieldEditor == true`; a standalone `NSTextView` has it `false`.

## Why it looked like a double-click bug, and why ~1% worked

The caret appeared and vanished within a frame or two, which reads as "the double-click
didn't take". And `TapGesture` requires the pointer not to move, so a double-click with
a little drift never fired the callback and the edit survived — the occasional success
that made it feel intermittent rather than systematic.

The same instrumentation explains why creating a box with the **T** tool always worked:
that edit begins asynchronously, from `editRequest` after `waitForWrites`, long after
the tap has ended. Nothing follows it to blur it.

## Files changed

- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `isSearchFieldEditor(_:)` and the
  narrowed guard
- `AtelierRefs/AtelierRefsTests/SearchFieldBlurTests.swift` — new, 3 cases

## Tests

The regression is pinned on the real objects, not a mock: the window's actual field
editor must be blurrable, a standalone `NSTextView` must not be, and neither must a
plain view, a button, a window or `nil`. The middle case asserts both halves of the trap
— that an `NSTextView` *is* an `NSText` (which is why the old guard fired) and that its
`isFieldEditor` is `false` (which is why the new one doesn't).

## Note on the fixes that came before this one

269 (the `v`/`f`/`t` shortcuts eating typed characters) and 270 (⌘Z while typing) were real bugs
found on the way here, and they stand. Neither was the cause of the reported symptom.
Worth recording honestly: three rounds of reasoning from the code found genuine faults
but not this one, and it took ten minutes of instrumenting the running app to land on
it. The blur came from a file that has nothing to do with the canvas.
