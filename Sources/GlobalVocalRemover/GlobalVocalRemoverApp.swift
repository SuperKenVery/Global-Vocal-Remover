import AudioToolbox
import AppKit

@MainActor
final class GlobalVocalRemoverApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = GlobalAudioController()
    private lazy var windowController = MainWindowController(controller: controller)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func configureMenu() {
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.badge.minus", accessibilityDescription: "Global Vocal Remover")
        statusItem.button?.title = " GVR"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Controls", action: #selector(showControls), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start", action: #selector(start), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func showControls() {
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func start() {
        Task { @MainActor in
            do {
                try controller.start()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func stop() {
        controller.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    static func runSelfTest(useCoreML: Bool) throws {
        let separator = try VocalSeparator(useCoreML: useCoreML)
        let frames = VocalSeparator.outputChunkFrames
        let input = [Float](repeating: 0, count: frames * VocalSeparator.channels)
        var output = [Float](repeating: 0, count: frames * VocalSeparator.channels)
        input.withUnsafeBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                separator.process(
                    input: inputPointer.baseAddress!,
                    output: outputPointer.baseAddress!,
                    frames: frames,
                    channels: VocalSeparator.channels,
                    sampleRate: VocalSeparator.sampleRate
                )
            }
        }
    }
}

@main
@MainActor
enum GlobalVocalRemoverMain {
    private static var delegate: GlobalVocalRemoverApp?

    static func main() {
        if CommandLine.arguments.contains("--help") {
            printHelp()
            return
        }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--self-test-cpu") {
            runSelfTestAndExit()
            return
        }
        if CommandLine.arguments.contains("--start-smoke-test") {
            runStartSmokeTestAndExit()
            return
        }
        if CommandLine.arguments.contains("--debug-run") {
            runDebugCaptureAndExit()
            return
        }

        let app = NSApplication.shared
        let appDelegate = GlobalVocalRemoverApp()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }

    private static func runSelfTestAndExit() {
        do {
            try GlobalVocalRemoverApp.runSelfTest(useCoreML: !CommandLine.arguments.contains("--self-test-cpu"))
            print("GlobalVocalRemover self-test passed")
        } catch {
            fputs("GlobalVocalRemover self-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runStartSmokeTestAndExit() {
        do {
            let controller = GlobalAudioController()
            try controller.start()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            controller.stop()
            print("GlobalVocalRemover start smoke-test passed")
        } catch {
            fputs("GlobalVocalRemover start smoke-test failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runDebugCaptureAndExit() {
        do {
            let duration = try doubleArgument("--duration", defaultValue: 10)
            let debugDir = stringArgument("--debug-dir")
                .map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("global-vocal-remover-debug-\(Int(Date().timeIntervalSince1970))")
            let defaultOutput = try AudioObjectID.systemObject.readDefaultOutputDevice()
            let sampleRate = UInt32((try? defaultOutput.readNominalSampleRate()) ?? Double(VocalSeparator.sampleRate))
            let recorder = try AudioDebugRecorder(directory: debugDir, sampleRate: sampleRate)
            let controller = GlobalAudioController()
            var recorderClosed = false
            defer {
                controller.stop()
                if !recorderClosed {
                    try? recorder.close()
                }
            }

            try controller.start(debugRecorder: recorder)
            print("GlobalVocalRemover debug capture started")
            print("directory: \(debugDir.path)")
            print("duration: \(String(format: "%.2f", duration)) seconds")
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
            controller.stop()
            try recorder.close()
            recorderClosed = true
            print("GlobalVocalRemover debug capture written")
            print("capture: \(recorder.captureURL.path)")
            print("processed: \(recorder.processedURL.path)")
            print("metadata: \(recorder.metadataURL.path)")
        } catch {
            fputs("GlobalVocalRemover debug capture failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func stringArgument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        return CommandLine.arguments[index + 1]
    }

    private static func doubleArgument(_ name: String, defaultValue: Double) throws -> Double {
        guard let value = stringArgument(name) else { return defaultValue }
        guard let parsed = Double(value), parsed > 0 else {
            throw CLIError.invalidArgument("\(name) must be a positive number")
        }
        return parsed
    }

    private static func printHelp() {
        print("""
        GlobalVocalRemover

        Options:
          --debug-run --duration <seconds> --debug-dir <path>
              Capture system tap input and processed output as float32 stereo raw files, then exit.
          --start-smoke-test
              Start the tap for 3 seconds, then stop.
          --self-test
              Run one model chunk with Core ML execution provider.
          --self-test-cpu
              Run one model chunk on CPU.
        """)
    }
}

private enum CLIError: Error, LocalizedError {
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArgument(message):
            message
        }
    }
}
