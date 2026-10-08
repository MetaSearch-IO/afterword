import AfterwordCore
import SwiftUI

struct MeetingListRow: View {
    let meeting: Meeting
    let isSelected: Bool
    var processingStage: String?
    @State private var showingStatusDetails = false
    @State private var hoveringRow = false
    @State private var hoveringDetails = false
    @State private var detailsPinned = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var selectedForeground: Bool { isSelected && controlActiveState == .key && !showingStatusDetails }
    private var secondary: Color { selectedForeground ? .white.opacity(0.85) : .secondary }
    private var status: MeetingStatus { .primary(meeting, stage: processingStage) }
    private var keepingDetailsOpen: Bool { hoveringRow || hoveringDetails || detailsPinned }
    private var statusHelp: String {
        guard meeting.captureState == .interrupted else { return status.explanation }
        var parts = ["Processing: \(status.explanation)",
                     "Recording: \(MeetingStatus.recording(meeting).explanation)"]
        if !meeting.chunks.isEmpty { parts[1] += " The recording may be incomplete." }
        if let error = meeting.captureError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            parts.append("Reason: \(error)")
        }
        return parts.joined(separator: "\n\n")
    }
    private var statusColor: Color {
        if selectedForeground { return .white }
        switch status.tone {
        case .recording: return .red
        case .active: return .blue
        case .success: return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).fontWeight(.medium).lineLimit(2)
                .foregroundStyle(selectedForeground ? .white : .primary)
            HStack(spacing: 4) {
                Text(MeetingStatus.date(meeting.startedAt)).lineLimit(1)
                if meeting.retainedDurationUS > 0 {
                    Text("·")
                    let seconds = meeting.retainedDurationUS / 1_000_000
                    Text(String(format: "%lld:%02lld", seconds / 60, seconds % 60)).monospacedDigit()
                }
            }.font(.caption).foregroundStyle(secondary)
            Label {
                Text(status.title).foregroundStyle(selectedForeground ? .white : .primary)
            } icon: {
                Image(systemName: status.symbol).foregroundStyle(statusColor)
            }.font(.caption).lineLimit(1)
            if meeting.captureState == .interrupted {
                Button {
                    if showingStatusDetails {
                        showingStatusDetails = false
                    } else {
                        detailsPinned = true
                        showingStatusDetails = true
                    }
                } label: {
                    Label("Recording interrupted", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(selectedForeground ? .white : .orange)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("Recording interrupted. Show details")
                .accessibilityIdentifier("meeting-status-details")
            }
            if let available = MeetingStatus.savedResults(meeting) {
                Text(available).font(.caption).foregroundStyle(secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityHint(statusHelp)
        .onHover { hoveringRow = $0 }
        .task(id: hoveringRow) {
            guard hoveringRow, !showingStatusDetails else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled, hoveringRow else { return }
            showingStatusDetails = true
        }
        .task(id: keepingDetailsOpen) {
            guard !keepingDetailsOpen else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, !keepingDetailsOpen else { return }
            showingStatusDetails = false
        }
        .popover(isPresented: $showingStatusDetails, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(status.title).font(.headline)
                    Text(status.explanation).fixedSize(horizontal: false, vertical: true)
                }
                if meeting.captureState == .interrupted {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Recording interrupted", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text(meeting.chunks.isEmpty ? "Recording ended unexpectedly. No audio was saved."
                             : "Audio capture stopped unexpectedly. Part of the meeting may be missing from the saved audio, transcript, and notes.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = meeting.captureError?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Reason").font(.headline)
                            Text(error).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("meeting-recording-reason")
                        }
                    }
                }
            }
            .font(.body)
            .lineLimit(nil)
            .textSelection(.enabled)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .foregroundStyle(.primary)
            .onHover { hoveringDetails = $0 }
        }
        .onChange(of: showingStatusDetails) { _, visible in
            if !visible {
                detailsPinned = false
                hoveringDetails = false
            }
        }
    }
}
