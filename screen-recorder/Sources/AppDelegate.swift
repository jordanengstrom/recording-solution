import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--smoke-test") else { return }

        let outputDirectory: URL
        if let flagIndex = arguments.firstIndex(of: "--output-directory"),
           arguments.indices.contains(flagIndex + 1) {
            outputDirectory = URL(fileURLWithPath: arguments[flagIndex + 1], isDirectory: true)
        } else {
            outputDirectory = FileManager.default.temporaryDirectory
        }

        let smokeCycles: Int
        if let flagIndex = arguments.firstIndex(of: "--smoke-cycles"),
           arguments.indices.contains(flagIndex + 1),
           let parsedCycles = Int(arguments[flagIndex + 1]),
           parsedCycles > 0 {
            smokeCycles = parsedCycles
        } else {
            smokeCycles = 1
        }

        Task { @MainActor in
            for cycle in 1...smokeCycles {
                guard let outputURL = await RecorderController.shared.runSmokeTest(
                    durationSeconds: 3,
                    outputDirectory: outputDirectory
                ) else {
                    fputs(
                        "SMOKE_TEST_FAILED=\(RecorderController.shared.statusDetail)\n",
                        stderr
                    )
                    fflush(stderr)
                    exit(2)
                }
                print("SMOKE_TEST_OK_CYCLE_\(cycle)=\(outputURL.path)")
            }
            fflush(stdout)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        RecorderController.shared.displayParametersDidChange()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        RecorderController.shared.recheckPermission()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecorderController.shared.isBusy else {
            return .terminateNow
        }

        RecorderController.shared.stopForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
