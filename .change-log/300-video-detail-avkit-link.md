# 300 — opening a video crashed the app

## Summary

Opening any video item on the detail page killed the app — `abort()` on the main
thread, from inside the Swift runtime, with no frame of ours anywhere near the
top:

```
3   libswiftCore.dylib   swift::fatalErrorv(...)
5   libswiftCore.dylib   getSuperclassMetadata + 828
7   _AVKit_SwiftUI       0x23a86c974
...
27  SwiftUI              ViewResponderFilter.init(inputs:view:)
31  SwiftUICore          static CoreViewRepresentable._makeView(view:inputs:)
```

The message the runtime prints before aborting (not captured in the crash report,
but reproduced locally) names the problem exactly:

```
failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'
```

It is a link-time problem, not a media problem. The video's origin, container,
and codec are irrelevant — the crash happens while SwiftUI is building the view,
before the player is ever asked to draw a frame.

## 1. Why AVKit was not in the process

`VideoPlayer` does not live in SwiftUI or in AVKit. It lives in
`_AVKit_SwiftUI`, the cross-import overlay that exists only because both are
imported, and its backing `NSView` (`VideoPlayerView`) subclasses AVKit's
`AVPlayerView`. That superclass is not a link-time reference — Swift records it
as a mangled name and resolves it through `swift_getTypeByMangledName` the first
time SwiftUI instantiates the representable. Resolution needs AVKit to be loaded
in the process; if it is not, the runtime has no recovery path and traps.

Nothing loaded it:

- The overlay does not link it. `dyld_info -dependents` on `_AVKit_SwiftUI`
  lists SwiftUI, AVFoundation, and the Swift shims — no AVKit.
- We did not link it either. `import AVKit` emits an autolink hint (confirmed as
  `-framework AVKit` in `ItemDetailView.o`'s `LC_LINKER_OPTION`), but autolinked
  frameworks are implicit, and the linker drops an implicit framework when the
  binary references none of its symbols. Every AVKit-adjacent symbol we touch is
  somewhere else: `AVPlayer` is AVFoundation, `VideoPlayer` is the overlay. So
  AVKit had no used symbol, and `otool -L` on the shipped 1.0 binary lists
  `_AVKit_SwiftUI` with no AVKit beside it.

Reproduced standalone — an `NSHostingView` wrapping `VideoPlayer` and forced to
lay out aborts with the message above when AVKit is absent, and prints its view
fine when a single AVKit symbol reference is added.

## 2. The fix

`linkAVKit()` in `ItemDetailView.swift` touches `AVPlayerView` through
`NSStringFromClass`, and `loadMedia()` calls it on the `.video` arm before the
media area builds its player. That is a real symbol reference, so the framework
survives the link: the rebuilt Release binary now lists

```
/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit
/System/Library/Frameworks/_AVKit_SwiftUI.framework/Versions/A/_AVKit_SwiftUI
```

A code anchor rather than an entry in Link Binary With Libraries, deliberately:
adding AVKit to the target's frameworks phase fixes today's build (an explicit
`-framework` is kept where an implicit one is pruned), but it is invisible at the
call site and would go away again under `-dead_strip_dylibs`. A referenced symbol
cannot be pruned by any link setting, and it sits next to the `VideoPlayer` that
depends on it. `NSStringFromClass` is an imported C function, so the optimizer
cannot delete the call — verified at `-O`.

## 3. How long this was broken

Since `ce9901a` (2026-07-13), the commit that introduced the detail page and the
only commit in the repo's history that has ever added `import AVKit`. No code has
ever referenced an AVKit symbol directly — `git log -S "AVPlayerView"` is empty —
so nothing masked it in the meantime.

Not Release-only, despite surfacing in a shipped build: none of the Debug builds
in DerivedData link AVKit either. Every build since 2026-07-13 crashed on the
first video opened; it went unnoticed because video items are rare next to
images, and image, color, link, and tweet items never reach the AVKit path.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `linkAVKit()`, called from
  `loadMedia()`'s `.video` arm.

## Migration notes

None. No schema, storage, or API change; existing video items open as they were
always meant to. Requires a rebuild — the fix is in the link, so a running 1.0
binary stays broken until replaced.
