import SwiftUI

struct TranscriptionLanguagePicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Auto (中文 / English)").tag("auto")
            Text("中文").tag("zh")
            Text("English").tag("en")
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
