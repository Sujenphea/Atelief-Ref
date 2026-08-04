//
//  ToastHost.swift
//  AtelierRefs
//
//  011-B4 · 4A — the shell-level presentation for capture toasts: the
//  `ToastCenter` owner (real clock + a single purge timer over the pure
//  ``ToastQueue``) and the bottom-trailing host overlay that renders the live
//  toasts and fires their typed Jump action. Kept thin — the coalescing / expiry
//  / cap logic all lives (and is tested) in ``ToastQueue``.
//

import Combine
import Foundation
import SwiftUI

/// Owns the live toast queue and drives real-time expiry. The only stateful,
/// non-pure part of the toast feature (hence not unit-tested — the queue is).
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var queue = ToastQueue()
    private var purgeTask: Task<Void, Never>?

    /// Post (or coalesce) a toast now and (re)arm the purge timer.
    func post(message: String, action: ToastAction? = nil, coalesceKey: String) {
        queue.enqueue(message: message, action: action, coalesceKey: coalesceKey, now: Date())
        schedulePurge()
    }

    func dismiss(_ id: UUID) {
        queue.dismiss(id)
        schedulePurge()
    }

    /// Sleep until the next toast expires, purge, and re-arm — so expired cards
    /// disappear on their own without a always-on ticking timer.
    private func schedulePurge() {
        purgeTask?.cancel()
        guard let next = queue.nextExpiry else { purgeTask = nil; return }
        let delay = max(0, next.timeIntervalSinceNow)
        purgeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.queue.purgeExpired(now: Date())
            self.schedulePurge()
        }
    }
}

/// The bottom-trailing toast stack, overlaid on the whole shell. Empty space is
/// not hittable (a bare `VStack` claims only its cards' footprint), so it never
/// steals clicks from the screen beneath.
///
/// **Placement.** This overlay sits on the SHELL, so its insets are measured from
/// the WINDOW — while the floating "+" and the selection action bar are overlays on
/// the PANE, and measure from the content panel (itself inset `Spacing.md` from the
/// window). The stack used to take a bare `.padding()`, which put its ~16pt-tall
/// footprint straight through the "+" disc that starts 28pt up: an opaque, hittable
/// card parked on the button for the full 6s TTL. So the bottom inset is derived
/// rather than guessed — it clears the disc and the toasts rise ABOVE it. The
/// trailing inset stays at the corner margin every floating pill uses; lifted this
/// far up, the card is clear of the panel's 16pt corner arc, so it needs no extra
/// inset to avoid overhanging it.
struct ToastHostView: View {
    /// Window-edge margin. Deliberately NOT the "+"'s 28pt (panel inset + its own
    /// margin): a toast is a wide card, and pushing it further in than the pill it
    /// stacks over reads as misalignment, not breathing room.
    private static let trailingInset = Theme.Spacing.lg
    /// Clear the floating "+" entirely: panel inset (`md`) + the button's own bottom
    /// margin (`lg`) + its 40pt diameter + a `sm` gap between the two.
    private static let bottomInset =
        Theme.Spacing.md + Theme.Spacing.lg + 40 + Theme.Spacing.sm

    @ObservedObject var center: ToastCenter
    /// Perform a Jump (validated + routed by the shell).
    let onJump: (JumpTarget) -> Void
    /// Undo the destructive action a toast describes, guarded by its post-time
    /// undo-stack token (034 P1).
    let onUndo: (Int) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.queue.toasts) { toast in
                ToastCard(
                    toast: toast,
                    onAction: {
                        switch toast.action {
                        case let .jump(target): onJump(target)
                        case let .undo(token): onUndo(token)
                        case .none: break
                        }
                        center.dismiss(toast.id)
                    },
                    onDismiss: { center.dismiss(toast.id) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.trailing, Self.trailingInset)
        .padding(.bottom, Self.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(Theme.Motion.toast, value: center.queue.toasts)
    }
}

/// One toast card: a message, an optional typed-action button, and a close ✕.
struct ToastCard: View {
    let toast: Toast
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(toast.message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.inkPrimary)
                .lineLimit(2)
            if let label = actionLabel {
                Button(label, action: onAction)
                    .buttonStyle(DialogButtonStyle(width: .hug))
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: Theme.Radius.chip, padding: Theme.Spacing.xs))
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.md)
        // Opaque `surface`, not `.regularMaterial`: a translucent pill tints from
        // whatever it happens to be floating over, so the same toast rendered a
        // different grey on the grid than on the canvas. `Elevation.floating` is the
        // token for exactly this shape — a pill riding over content it did not lay out
        // — which replaces the one-off 0.15/8/3 shadow this card used to carry.
        .background(Theme.Colors.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
        .elevation(.floating)
        // `.trailing`, not the default `.center`: this frame sits OUTSIDE the capsule
        // background, and the host proposes an infinite width down through the stack,
        // so it always resolves to the full 420 — a short pill was being centred in it
        // with up to ~90pt of invisible slack on either side. The stack's own
        // `alignment: .trailing` couldn't correct that; it aligns these frames, not the
        // pills inside them, which is why a "Reordered 8 items." toast floated a hundred
        // points off the edge while the "+" sat flush. The cap still does its real job —
        // it's the width proposed to the message, so a long one wraps to two lines
        // instead of stretching into a banner.
        .frame(maxWidth: 420, alignment: .trailing)
    }

    /// The action button's label, or `nil` for a bare message. Jump carries its own
    /// label; Undo is always "Undo".
    private var actionLabel: String? {
        switch toast.action {
        case let .jump(target): return target.buttonLabel
        case .undo: return "Undo"
        case .none: return nil
        }
    }
}
