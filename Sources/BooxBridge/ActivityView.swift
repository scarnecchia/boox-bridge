// pattern: Mixed (unavoidable) — presentation reads app state directly.

import BooxBridgeCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        List {
            Section("OCR Queue") {
                queueSection
            }
            Section("Import") {
                if app.importSummaries.isEmpty {
                    Text("No imports this session.")
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.importSummaries.sorted(by: { $0.key < $1.key }), id: \.key) { rootID, summary in
                        VStack(alignment: .leading, spacing: Metrics.activityRowSpacing) {
                            Text(rootID).font(TypeStyles.rowTitle).lineLimit(1)
                            Text(app.summaryDescription(summary))
                                .font(TypeStyles.rowSecondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            ForEach(summary.deferredUnstable, id: \.self) { note in
                                Label(note, systemImage: "clock.badge.exclamationmark")
                                    .font(TypeStyles.rowSecondary)
                            }
                            ForEach(summary.invalidFiles, id: \.path) { invalid in
                                Label("\(invalid.path): \(invalid.reason)", systemImage: "exclamationmark.triangle")
                                    .font(TypeStyles.rowSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section("History") {
                if app.activity.isEmpty {
                    Text("Nothing yet.")
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.activity) { event in
                        VStack(alignment: .leading, spacing: Metrics.activityRowSpacing) {
                            Text(event.title).font(TypeStyles.rowTitle).lineLimit(1).truncationMode(.tail)
                            if let detail = event.detail {
                                Text(detail).font(TypeStyles.rowSecondary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Text(event.date.formatted(date: .abbreviated, time: .standard))
                                .font(TypeStyles.monoDetail)
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .onAppear { app.refreshLibrary() }
    }

    /// Active jobs first (with Cancel/Resume), then persisted terminal jobs —
    /// failures with reasons and completed pages — each failed row offering an
    /// explicit retry. Kept as one flat section: the queue and its history are
    /// the same pipeline seen from two moments.
    @ViewBuilder
    private var queueSection: some View {
        if app.activeJobs.isEmpty && app.jobHistory.isEmpty {
            Text("No transcription jobs yet.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
        } else {
            ForEach(app.activeJobs) { job in
                OCRJobRow(job: job, retryAction: nil)
            }
            if !app.activeJobs.isEmpty {
                HStack {
                    Spacer()
                    if app.isOCRDraining {
                        Button("Cancel OCR") { app.cancelOCRDrain() }
                            .accessibilityLabel("Cancel OCR work")
                    } else {
                        Button("Resume OCR") { app.startOCRDrain() }
                            .accessibilityLabel("Resume queued OCR work")
                    }
                }
            }
            ForEach(app.jobHistory) { job in
                OCRJobRow(job: job,
                          retryAction: job.state == .failed ? { app.retryOCRJob(job) } : nil)
            }
        }
    }
}

/// One transcription job row. Terminal failures keep their persisted reason
/// visible so auth/render failures outlive the drain that produced them.
private struct OCRJobRow: View {
    let job: OcrJob
    let retryAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.activityRowSpacing) {
            VStack(alignment: .leading, spacing: Metrics.activityQueueRowSpacing) {
                HStack {
                    Image(systemName: iconName)
                        .foregroundStyle(iconTint)
                    Text("Page \(job.pageIndex + 1) · \(job.modelID)")
                        .font(TypeStyles.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(job.state.rawValue.capitalized)
                        .font(TypeStyles.monoDetail)
                        .foregroundStyle(.secondary)
                }
                if let error = job.lastError {
                    Text(error)
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)
            if let retryAction {
                Button("Retry", action: retryAction)
                    .accessibilityLabel("Retry OCR for page \(job.pageIndex + 1)")
            }
        }
    }

    private var iconName: String {
        switch job.state {
        case .running: return "arrow.triangle.2.circlepath"
        case .queued: return "clock"
        case .succeeded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "slash.circle"
        }
    }

    private var iconTint: Color {
        switch job.state {
        case .running: return .accentColor
        case .failed: return .orange
        default: return .secondary
        }
    }
}
