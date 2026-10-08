import AfterwordCore
import SwiftUI

struct MeetingTitleEditor: View {
    let meeting: Meeting
    @ObservedObject var controller: MeetingController
    @State private var editing = false
    @State private var saving = false
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if editing {
                    TextField("Meeting name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                        .disabled(saving)
                    Button("Save", action: save)
                        .disabled(saving || !controller.canRenameMeeting(meeting))
                    Button("Cancel") { editing = false; error = nil }
                        .disabled(saving)
                } else {
                    Text(meeting.title).font(.title2)
                    Spacer()
                    Button("Rename") { draft = meeting.title; error = nil; editing = true }
                        .disabled(!controller.canRenameMeeting(meeting))
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            do {
                try await controller.renameMeeting(id: meeting.id, title: draft)
                editing = false
                error = nil
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
