import SwiftUI
import LecternCore

/// "Choose mic" from a transcript warning: picking an input restarts capture on it (or resumes a
/// lecture that paused because transcription stopped).
struct MicChooser: View {
    var session: LiveSessionModel

    /// Notices whose action opens this chooser.
    static let noticeIDs: Set<String> = ["engine", "silence"]

    var body: some View {
        let devices = session.inputDevices
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Record from").font(DS.Typo.subheadline).foregroundStyle(.secondary)
            if devices.isEmpty {
                Text("No microphones found").font(DS.Typo.subheadline)
            }
            ForEach(devices) { device in
                Button {
                    session.switchInputDevice(device.id)
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "checkmark").opacity(device.id == session.inputDeviceID ? 1 : 0)
                        Text(device.isDefault ? "\(device.name) (system default)" : device.name)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Space.m)
        .frame(minWidth: 220, alignment: .leading)
    }
}
