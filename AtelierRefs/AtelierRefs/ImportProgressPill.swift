//
//  ImportProgressPill.swift
//  AtelierRefs
//
//  059 · SP3 / 5A — the floating import-progress pill (222), shared by the
//  collection grid AND an open Space board so a drop / paste batch reports the
//  SAME way on both surfaces (before SP3 this lived privately in CollectionView,
//  so a board import showed no progress). Renders nothing when no batch is active.
//

import SwiftUI

struct ImportProgressPill: View {
    let progress: IngestionModel.Progress?

    var body: some View {
        if let progress {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView(
                    value: Double(progress.completed),
                    total: Double(max(progress.total, 1)))
                .frame(width: 120)
                Text("\(progress.completed) / \(progress.total)")
                    .font(Theme.Typography.caption).monospacedDigit()
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            // The shared container, not a fourth hand-written copy of it. This pill
            // used to declare the fill / border / shadow itself and pad V8 where the
            // modifier pads V6 — one point taller than the selection bar it sits
            // directly above on the collection screen.
            .floatingBarChrome(leading: Theme.Spacing.lg, trailing: Theme.Spacing.lg)
        }
    }
}
