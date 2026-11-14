// pattern: Mixed (unavoidable) — presentation reads app state directly.

import BooxBridgeCore
import SwiftUI

struct ActivityView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        List {
            Section("OCR Queue") {
                if app.activeJobs.isEmpty {
                    Text("No OCR jobs waiting.")
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.activeJobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: job.state == .running ? "arrow.triangle.2.circlepath" : "clock")
                                    .foregroundStyle(job.state == .running ? Color.accentColor : Color.secondary)
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
                    }
                    Button("Cancel OCR") { app.cancelOCRDrain() }
                        .accessibilityLabel("Cancel OCR work")
                }
            }
            Section("Import") {
                if app.importSummaries.isEmpty {
                    Text("No imports this session.")
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.importSummaries.sorted(by: { $0.key < $1.key }), id: \.key) { rootID, summary in
                        VStack(alignment: .leading, spacing: 2) {
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
                        VStack(alignment: .leading, spacing: 2) {
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
        .frame(minWidth: 440, minHeight: 380)
        .onAppear { app.refreshLibrary() }
    }
}
