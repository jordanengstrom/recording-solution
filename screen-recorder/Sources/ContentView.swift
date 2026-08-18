import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 42))
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .accessibilityHidden(true)

            Text(recorder.statusTitle)
                .font(.headline)

            Text(recorder.statusDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
                .lineLimit(4)

            Button(action: recorder.toggleRecording) {
                Text(recorder.buttonTitle)
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!recorder.canToggle)
            .keyboardShortcut(.space, modifiers: [.command])

            if recorder.permissionWasDenied {
                VStack(spacing: 10) {
                    HStack(spacing: 14) {
                        Button("Open Privacy Settings") {
                            recorder.openPrivacySettings()
                        }
                        Button("Recheck Permission") {
                            recorder.recheckPermission()
                        }
                    }

                    Button("Quit & Reopen") {
                        recorder.quitAndReopen()
                    }

                    Text("Running: \(recorder.runningBundlePath)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if !recorder.isRunningInstalledCopy {
                        Text("For persistent permission, run the installed copy at \(recorder.canonicalInstallPath).")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 390)
        .frame(minHeight: 240)
    }
}
