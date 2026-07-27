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
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.field, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        }
    }
}
