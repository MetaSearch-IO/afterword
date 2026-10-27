import AfterwordCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReviewPane: View {
    let meeting: Meeting
    @ObservedObject var controller: MeetingController
    @ObservedObject var processing: ProcessingController
    @State private var transcript: Transcript?
    @State private var summary: MeetingSummary?
    @State private var error: String?
    @State private var selectedSegment: String?
    @State private var drafts: [String: String] = [:]
    @State private var confirmReprocess = false
    @State private var showEvidence = false
    @State private var showTranscriptDetails = false
    @State private var savedSpeaker: String?
    @State private var correctingSpeakers = false
    @State private var correctionSelection = Set<String>()
    @State private var correctionSpeaker = ""
    @State private var canUndoCorrection = false
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchNavigation = 0
    @State private var exporting = false
    @State private var inviteeNames: [String] = []
    @State private var voiceLabels: [String: String] = [:]
    @AppStorage(RemoteProcessing.preferenceKey) private var remoteEnabled = true
    @FocusState private var searchFocused: Bool

    private var names: [String: String] { meeting.speakerNames[meeting.activeRevisionID ?? ""] ?? [:] }
    private var displayNames: [String: String] { voiceLabels.merging(names) { _, manual in manual } }
    private var canProcessAudio: Bool { controller.canProcess(meeting) }
    private var canRegenerateNotes: Bool { controller.canProcess(meeting, summaryOnly: true) }
    private var canCorrect: Bool {
        controller.activity == .idle && !controller.isLoading && !processing.cleanupBlocked
            && !processing.isMeetingBusy(meeting.id) && !meeting.captureState.isActive
            && controller.deletingMeetingID != meeting.id
    }
    private var identity: String { "\(meeting.id)/\(meeting.activeRevisionID ?? "")/\(meeting.activeSummaryID ?? "")" }
    private var searchMatches: [String] {
        transcript.map { TranscriptSearch.matches(searchQuery, transcript: $0, names: displayNames) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if meeting.audioUnavailable {
                Text(meeting.audioRemovedAt == nil
                     ? "Audio removal is incomplete. Finish removing audio before processing this meeting."
                     : "Saved audio was removed. Existing transcripts and notes remain available; playback and audio reprocessing are unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TranscriptionLanguagePicker(title: "Language for reprocessing", selection: Binding(
                get: { meeting.asrLanguage ?? "auto" },
                set: { language in
                    do { try processing.setTranscriptionLanguage(language, meeting: meeting) }
                    catch { self.error = error.localizedDescription }
                }))
                .disabled(!canProcessAudio)
            Text("Language changes apply to the next full transcription. Regenerating notes reuses the current transcript.")
                .font(.caption).foregroundStyle(.secondary)
            Text(remoteEnabled
                 ? "Hyperion is selected. Full processing sends prepared audio; regenerating notes sends the transcript. Change this in Settings before queuing."
                 : "This Mac is selected for new processing jobs. Change this in Settings to use Hyperion.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if meeting.activeRevisionID == nil {
                    Button("Process Saved Audio") { processing.start(meeting) }.disabled(!canProcessAudio)
                } else {
                    Button("Regenerate Notes") { processing.start(meeting, summaryOnly: true) }.disabled(!canRegenerateNotes)
                    if transcript?.speakerLabelsPending == true {
                        Button("Finish Speaker Labels") { processing.start(meeting) }.disabled(!canProcessAudio)
                            .help("Reuse compatible saved transcription to finish speaker labels and notes.")
                    } else {
                        Button("Reprocess Audio…") { confirmReprocess = true }.disabled(!canProcessAudio)
                    }
                    exportMenu
                }
            }
            .confirmationDialog("Reprocess audio with new speaker IDs?", isPresented: $confirmReprocess, titleVisibility: .visible) {
                Button("Reprocess Audio") { processing.start(meeting) }
            } message: {
                Text("The current transcript stays available until a new transcript succeeds. Speaker names reset for the new revision; old cluster numbers will not inherit names.")
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let transcript {
                if transcript.segments.isEmpty {
                    Text(meeting.audioUnavailable ? "No speech was found before the saved audio was removed."
                         : "No speech was found in the retained audio.").foregroundStyle(.secondary)
                } else {
                    speakerEditor(transcript)
                        .disabled(transcript.speakerLabelsPending && processing.isBusy && processing.meetingID == meeting.id)
                    let pauses = zip(meeting.intervals, meeting.intervals.dropFirst()).compactMap { previous, next -> String? in
                        guard let end = previous.endUS, next.startUS > end else { return nil }
                        return "\(timestamp(end))–\(timestamp(next.startUS))"
                    }
                    if !pauses.isEmpty {
                        Text("Recording paused: " + pauses.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 16) {
                            if let summary {
                                HStack {
                                    Text("Notes").font(.title3.bold())
                                    Spacer()
                                    Toggle("Show evidence timestamps", isOn: $showEvidence)
                                        .toggleStyle(.checkbox).font(.caption)
                                }
                                if summary.name_map_revision != (try? Artifacts.nameMapRevision(names)) {
                                    Text("Speaker names changed after these notes were generated. Structured owners use the current names; regenerate notes to update their prose.")
                                        .font(.callout).foregroundStyle(.orange)
                                }
                                if showEvidence {
                                    notes("Overview", summary.overview)
                                    notes("Discussion", summary.discussion_points)
                                    notes("Decisions", summary.decisions)
                                    if !summary.action_items.isEmpty {
                                        Text("Action items").font(.headline)
                                        ForEach(Array(summary.action_items.enumerated()), id: \.offset) { _, action in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(action.text).textSelection(.enabled)
                                                Text("Owner: \(speakerName(action.owner_speaker_id)) · Due: \(action.due_date ?? "Unspecified")")
                                                    .font(.caption).foregroundStyle(.secondary)
                                                evidence(action.segment_ids)
                                            }
                                        }
                                    }
                                    notes("Open questions", summary.open_questions)
                                } else {
                                    selectableNotes(summary)
                                        .textSelection(.enabled)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Divider()
                            HStack {
                                Text("Transcript").font(.headline)
                                Spacer()
                                Button { showSearch = true; searchFocused = true } label: { Label("Find", systemImage: "magnifyingglass") }
                                    .keyboardShortcut("f")
                                Toggle("Details", isOn: $showTranscriptDetails)
                                    .toggleStyle(.checkbox).font(.caption)
                                if controller.playbackInfo != nil { Button("Stop Playback") { controller.stopPlayback() } }
                            }
                            if showSearch { searchControls }
                            correctionControls(transcript)
                            if transcript.speakerLabelsPending {
                                Text("Speaker labels are pending. You can finish them later.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                let unknownCount = transcript.segments.filter { $0.speaker_id == nil }.count
                                if unknownCount > 0 {
                                    Text("\(unknownCount) segments have no confirmed speaker. Renaming changes labeled segments only.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let info = controller.playbackInfo { Text(info).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            if showTranscriptDetails {
                                ForEach(transcript.warnings, id: \.self) { warning in
                                    Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            LazyVStack(alignment: .leading, spacing: 2) {
                                let matches = Set(searchMatches)
                                let compact = !showTranscriptDetails && !showSearch && !correctingSpeakers
                                ForEach(TranscriptRows.make(transcript.segments, compact: compact)) { row in
                                    let segment = row.segments[0]
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if correctingSpeakers {
                                            if eligibleForCorrection(segment) {
                                                Toggle("", isOn: Binding(
                                                    get: { correctionSelection.contains(segment.id) },
                                                    set: { selected in
                                                        if selected { correctionSelection.insert(segment.id) }
                                                        else { correctionSelection.remove(segment.id) }
                                                    }))
                                                    .toggleStyle(.checkbox).labelsHidden()
                                                    .accessibilityLabel("Select Unknown segment at \(timestamp(segment.start_us))")
                                                    .disabled(!canCorrect)
                                            } else { Color.clear.frame(width: 14, height: 14) }
                                        }
                                        Text(timestamp(row.startUS))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 52, alignment: .leading)
                                        Button { controller.play(source: row.source, startUS: row.startUS, endUS: row.endUS, in: meeting) } label: { Image(systemName: "play.circle") }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                            .help("Play this passage's retained audio")
                                            .accessibilityLabel("Play passage at \(timestamp(row.startUS))")
                                            .disabled(controller.activity != .idle || meeting.audioUnavailable)
                                        Text(speakerName(row.speakerID))
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .frame(width: 96, alignment: .leading)
                                            .help(speakerName(row.speakerID))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.text).textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            if showTranscriptDetails && (segment.speaker_id == nil || segment.overlap) {
                                                Text(attributionDescription(segment.attribution_reason))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 2)
                                    .background(row.segments.contains { $0.id == selectedSegment } ? Color.accentColor.opacity(0.12)
                                        : (row.segments.contains { matches.contains($0.id) } ? Color.yellow.opacity(0.12) : Color.clear))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .id(row.id)
                                }
                            }
                        }
                        .onChange(of: selectedSegment) { _, selected in
                            if let selected {
                                let compact = !showTranscriptDetails && !showSearch && !correctingSpeakers
                                let target = TranscriptRows.make(transcript.segments, compact: compact)
                                    .first { $0.segments.contains { $0.id == selected } }?.id ?? selected
                                withAnimation { proxy.scrollTo(target, anchor: .center) }
                            }
                        }
                        .onChange(of: searchNavigation) { _, _ in
                            if let selectedSegment { withAnimation { proxy.scrollTo(selectedSegment, anchor: .center) } }
                        }
                    }
                }
            } else if meeting.processingStatus != "empty" {
                Text("Local processing requires configured model files. Setup: make model-setup. Inspect: make model-inspect.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: identity) { load() }
        .onReceive(controller.calendar.$snapshotVersion) { _ in loadInviteeNames() }
        .onChange(of: meeting.processingStatus) { _, _ in refreshUndo() }
        .onChange(of: canCorrect) { _, _ in refreshUndo() }
        .onChange(of: searchQuery) { _, _ in selectedSegment = searchMatches.first }
    }

    private func load() {
        transcript = nil
        summary = nil
        error = nil
        drafts = [:]
        savedSpeaker = nil
        selectedSegment = nil
        showEvidence = false
        showTranscriptDetails = false
        correctingSpeakers = false
        correctionSelection = []
        correctionSpeaker = ""
        canUndoCorrection = false
        showSearch = false
        searchQuery = ""
        voiceLabels = [:]
        loadInviteeNames()
        guard meeting.activeRevisionID != nil else { return }
        do {
            let loaded = try processing.loadTranscript(meeting)
            transcript = loaded
            voiceLabels = (try? VoiceProfileLabels.load(store: controller.store, meetingID: meeting.id, transcript: loaded)) ?? [:]
            summary = try processing.loadSummary(meeting, transcript: loaded)
            correctionSpeaker = loaded.speakers.first { $0.source == .system }?.id ?? ""
            refreshUndo()
        } catch { self.error = error.localizedDescription }
    }

    private var searchControls: some View {
        HStack {
            TextField("Find transcript text or speaker", text: $searchQuery)
                .focused($searchFocused)
                .onSubmit { moveSearch() }
                .onExitCommand { showSearch = false; searchQuery = "" }
            let matches = searchMatches
            let position = selectedSegment.flatMap { matches.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            Text("\(position) of \(matches.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { moveSearch(backwards: true) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(matches.isEmpty).help("Previous match")
            Button { moveSearch() } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g").disabled(matches.isEmpty).help("Next match")
            Button { showSearch = false; searchQuery = "" } label: { Image(systemName: "xmark") }
                .help("Close search")
        }
    }

    private func moveSearch(backwards: Bool = false) {
        selectedSegment = TranscriptSearch.next(in: searchMatches, after: selectedSegment, backwards: backwards)
        searchNavigation += 1
    }

    private func eligibleForCorrection(_ segment: TranscriptSegment) -> Bool {
        segment.source == .system && segment.speaker_id == nil && !segment.overlap
    }

    private func correctionControls(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if transcript.speakers.contains(where: { $0.source == .system })
                    && transcript.segments.contains(where: eligibleForCorrection) {
                    Toggle("Correct speakers", isOn: $correctingSpeakers)
                        .toggleStyle(.checkbox).disabled(!canCorrect)
                }
                if canUndoCorrection {
                    Button("Undo Speaker Correction") { undoCorrection() }.disabled(!canCorrect)
                }
            }
            if correctingSpeakers {
                HStack {
                    Text("\(correctionSelection.count) selected").font(.caption).foregroundStyle(.secondary)
                    Picker("Assign to", selection: $correctionSpeaker) {
                        ForEach(transcript.speakers.filter { $0.source == .system }) { speaker in
                            Text(speakerName(speaker.id)).tag(speaker.id)
                        }
                    }.frame(maxWidth: 260)
                    Button("Assign Speaker") { assignSpeaker() }
                        .disabled(correctionSelection.isEmpty || correctionSpeaker.isEmpty)
                    Button("Clear") { correctionSelection = [] }.disabled(correctionSelection.isEmpty)
                }.disabled(!canCorrect)
                Text("Use the checkboxes to select Unknown remote lines. Overlapping speech cannot be assigned. Notes will need regeneration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshUndo() {
        canUndoCorrection = canCorrect && (try? SpeakerCorrections.correction(store: controller.store, meeting: meeting)) != nil
    }

    private func assignSpeaker() {
        guard let revision = meeting.activeRevisionID else { return }
        do {
            _ = try SpeakerCorrections.assign(store: controller.store, meetingID: meeting.id, expectedRevisionID: revision,
                                               segmentIDs: Array(correctionSelection), speakerID: correctionSpeaker)
            controller.stopPlayback()
            controller.reload()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func undoCorrection() {
        guard let revision = meeting.activeRevisionID else { return }
        do {
            _ = try SpeakerCorrections.undo(store: controller.store, meetingID: meeting.id, expectedRevisionID: revision)
            controller.stopPlayback()
            controller.reload()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private var exportMenu: some View {
        Menu("Export") {
            ForEach(ReviewExportFormat.allCases, id: \.self) { format in
                Menu(format.rawValue) {
                    ForEach(ReviewExportScope.allCases, id: \.self) { scope in
                        Button(scope.rawValue) { export(scope: scope, format: format) }
                    }
                }
            }
        }.disabled(transcript == nil || exporting)
    }

    private func export(scope: ReviewExportScope, format: ReviewExportFormat) {
        guard let revision = meeting.activeRevisionID else { return }
        do {
            let snapshot = try ReviewExport.snapshot(store: controller.store, meetingID: meeting.id,
                expectedRevisionID: revision, expectedSummaryID: meeting.activeSummaryID)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText]
            panel.nameFieldStringValue = ReviewExport.filename(title: snapshot.meeting.title, scope: scope, format: format)
            panel.canCreateDirectories = true
            exporting = true
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                exporting = false
                guard response == .OK, let url = panel.url else { return }
                do {
                    try ReviewExport.validateCurrent(snapshot, store: controller.store)
                    try Data(ReviewExport.render(snapshot, scope: scope, format: format).utf8).write(to: url, options: .atomic)
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        } catch { self.error = error.localizedDescription }
    }

    private func speakerEditor(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.headline)
            ForEach(transcript.speakers) { speaker in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speakerName(speaker.id))
                        Text("\(transcript.segments.filter { $0.speaker_id == speaker.id }.count) labeled segments")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 145, alignment: .leading)
                    TextField("Display name", text: Binding(
                        get: { drafts[speaker.id] ?? names[speaker.id] ?? "" },
                        set: { drafts[speaker.id] = $0; savedSpeaker = nil }))
                        .onSubmit { saveSpeaker(speaker.id) }
                        .accessibilityLabel("Display name for \(speakerName(speaker.id))")
                    Button("Save") { saveSpeaker(speaker.id) }
                    if !inviteeNames.isEmpty {
                        Menu("Use invitee name") {
                            ForEach(inviteeNames, id: \.self) { name in
                                Button(name) { drafts[speaker.id] = name; savedSpeaker = nil }
                            }
                        }
                        .help("Fill the display name, then Save. Calendar invitees are not identified speakers.")
                    }
                    if savedSpeaker == speaker.id {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func saveSpeaker(_ id: String) {
        do {
            let name = (drafts[id] ?? names[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try processing.rename(meeting: meeting, speakerID: id, name: name)
            drafts[id] = name
            savedSpeaker = id
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadInviteeNames() {
        inviteeNames = (try? controller.calendar.snapshot(meetingID: meeting.id))?.event.nameSuggestions ?? []
    }

    private func selectableNotes(_ summary: MeetingSummary) -> Text {
        var result = Text("")
        var first = true
        func section(_ title: String, _ body: String) {
            guard !body.isEmpty else { return }
            if !first { result = result + Text("\n\n") }
            first = false
            result = result + Text(title + "\n").font(.headline) + Text(body)
        }
        func bullets(_ items: [SummaryNote]) -> String {
            items.map { "• " + $0.text }.joined(separator: "\n")
        }
        section("Overview", summary.overview.map(\.text).joined(separator: " "))
        section("Discussion", bullets(summary.discussion_points))
        section("Decisions", bullets(summary.decisions))
        section("Action items", summary.action_items.map {
            "• \($0.text)\n  Owner: \(speakerName($0.owner_speaker_id)) · Due: \($0.due_date ?? "Unspecified")"
        }.joined(separator: "\n"))
        section("Open questions", bullets(summary.open_questions))
        return result
    }

    private func attributionDescription(_ reason: String) -> String {
        switch reason {
        case "speaker_labeling_pending": "Speaker labeling is pending."
        case "incomplete_speaker_timing": "Speaker timing does not cover the entire segment."
        case "single_exclusive_turn_with_vad_padding": "One speaker covers the speech; detection padding was ignored."
        case "single_exclusive_turn_with_bounded_gap": "One speaker covers most detected speech with small timing gaps."
        case "speaker_change_or_missing_timing": "No single speaker could be confirmed for this segment."
        case "overlapping_remote_speech": "Multiple speakers overlap here."
        case "asr_timing_exceeds_retained_audio": "Timing extends beyond the retained audio."
        case "unresolved_asr_window_boundary": "Timing is uncertain near an audio-window boundary."
        case "diarization_unavailable": "Speaker labeling is unavailable."
        default: "Speaker attribution is uncertain."
        }
    }

    private func notes(_ title: String, _ items: [SummaryNote]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, note in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note.text).textSelection(.enabled)
                        evidence(note.segment_ids)
                    }
                }
            }
        }
    }

    private func evidence(_ ids: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 65, maximum: 100))], alignment: .leading) {
            ForEach(ids, id: \.self) { id in
                Button {
                    showTranscriptDetails = true
                    selectedSegment = id
                } label: {
                    Text(transcript?.segments.first(where: { $0.id == id }).map { timestamp($0.start_us) } ?? id)
                        .font(.caption)
                }
                .help("Show supporting transcript segment")
            }
        }
    }

    private func speakerName(_ id: String?) -> String {
        guard let id else { return "Unknown" }
        return displayNames[id] ?? transcript?.speakers.first(where: { $0.id == id })?.label ?? "Unknown"
    }

    private func timestamp(_ microseconds: Int64) -> String {
        let seconds = microseconds / 1_000_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
