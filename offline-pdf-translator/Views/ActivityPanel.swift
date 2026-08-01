//
//  ActivityPanel.swift
//  offline-pdf-translator
//

import SwiftUI

struct ActivityPanel: View {
    @Bindable var progress: TranslationProgress
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if progress.isActive {
                    ProgressView()
                        .controlSize(.small)
                } else if progress.stage == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if progress.stage == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.stage == .idle ? "Ready" : progress.stage.title)
                        .font(.caption.weight(.semibold))
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if progress.stage != .idle {
                    Text(progress.percentLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide activity log" : "Show activity log")
            }

            if progress.stage != .idle {
                ProgressView(value: progress.isIndeterminate ? nil : progress.fraction)
                    .progressViewStyle(.linear)
            }

            if isExpanded, !progress.events.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(progress.events) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(event.timeLabel)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(event.message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(event.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 120)
                    .onChange(of: progress.events.count) {
                        if let last = progress.events.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
