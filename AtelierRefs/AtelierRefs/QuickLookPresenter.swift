//
//  QuickLookPresenter.swift
//  AtelierRefs
//
//  Opens an asset's on-disk file in an inline QuickLook window — used to play a
//  captured video (a `.video` asset's canvas tile shows a poster; double-clicking
//  it plays here). `QLPreviewView` handles AV playback itself, so this needs no
//  responder-chain wiring. Retained by the presenting view so the window (and its
//  playback) survives; a second open reuses the same window.
//

import AppKit
import Quartz // QLPreviewView (QuickLookUI); QuickLook alone lacks the view

@MainActor
final class QuickLookPresenter {
    private var window: NSWindow?

    /// Present `url` in a QuickLook window titled `title`. No-op if the file is
    /// missing or a preview view can't be created.
    func present(url: URL, title: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { return }
        preview.previewItem = url as NSURL
        preview.autostarts = true

        let window = self.window ?? NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = title
        window.contentView = preview
        window.isReleasedWhenClosed = false
        if self.window == nil { window.center() }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
