import SwiftUI

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = RecorderController.shared

    var body: some Scene {
        WindowGroup("Screen Recorder") {
            ContentView()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

