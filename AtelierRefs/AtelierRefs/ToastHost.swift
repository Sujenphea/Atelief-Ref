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
struct ToastHostView: View {
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
        .padding()
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
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(toast.message)
                .font(Theme.Typography.body)
                .lineLimit(2)
            if let label = actionLabel {
                Button(label, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .frame(maxWidth: 420)
    }

    /// The leading glyph: a green check for a completed capture (Jump), an arrow for
    /// a reversible destructive verb (Undo).
    private var iconName: String {
        if case .undo = toast.action { return "arrow.uturn.backward.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if case .undo = toast.action { return .orange }
        return .green
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
