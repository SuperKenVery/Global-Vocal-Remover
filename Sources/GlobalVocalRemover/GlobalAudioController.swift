import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class GlobalAudioController {
    private let queue = DispatchQueue(label: "GlobalVocalRemover.Audio", qos: .userInitiated)
    private var separator: VocalSeparator?
    private var renderBox: AudioRenderBox?
    private var tapDescription: CATapDescription?
    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var originalDefaultOutputID = AudioObjectID.unknown
    private var running = false
    private var status = "Ready"

    var isRunning: Bool { running }
    var statusText: String { status }

    func start(debugRecorder: AudioDebugRecorder? = nil) throws {
        guard !running else { return }
        guard #available(macOS 14.2, *) else {
            throw CoreAudioError.osStatus(-1, "Core Audio Process Tap requires macOS 14.2 or newer")
        }

        try AudioCapturePermission.requestIfNeeded()
        separator = try VocalSeparator()
        originalDefaultOutputID = try AudioObjectID.systemObject.readDefaultOutputDevice()
        let outputUID = try originalDefaultOutputID.readDeviceUID()

        let excludedProcesses = selfProcessObjectsToExclude()
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tap.uuid = UUID()
        tap.name = "Global Vocal Remover Tap"
        tap.muteBehavior = .mutedWhenTapped
        tapDescription = tap

        var newTapID = AudioObjectID.unknown
        try checkOSStatus(AudioHardwareCreateProcessTap(tap, &newTapID), "Create process tap")
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Global Vocal Remover",
            kAudioAggregateDeviceUIDKey: "im.ken.GlobalVocalRemover.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID = AudioObjectID.unknown
        do {
            try checkOSStatus(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID), "Create aggregate device")
            aggregateDeviceID = newAggregateID
            guard aggregateDeviceID.waitUntilReady(timeout: 2.0) else {
                throw CoreAudioError.osStatus(-1, "Aggregate device not ready")
            }
            try createAndStartIOProc(debugRecorder: debugRecorder)
            try AudioObjectID.systemObject.setDefaultOutputDevice(aggregateDeviceID)
        } catch {
            cleanup()
            throw error
        }

        running = true
        let rate = (try? aggregateDeviceID.readNominalSampleRate()) ?? 0
        status = "Capturing global system audio via \(outputUID). Model path: Core ML. Device rate: \(Int(rate)) Hz."
    }

    private func selfProcessObjectsToExclude() -> [AudioObjectID] {
        var excluded: [AudioObjectID] = []
        for pid in [getpid(), getppid()] {
            guard let processObject = try? AudioObjectID.systemObject.translatePIDToProcessObjectID(pid),
                processObject != .unknown,
                !excluded.contains(processObject)
            else {
                continue
            }
            excluded.append(processObject)
        }
        return excluded
    }

    func stop() {
        cleanup()
        running = false
        status = "Stopped"
    }

    private func createAndStartIOProc(debugRecorder: AudioDebugRecorder?) throws {
        var newProcID: AudioDeviceIOProcID?
        guard let separator else {
            throw SeparatorError.invalidModelInterface
        }
        let sampleRate = UInt32((try? aggregateDeviceID.readNominalSampleRate()) ?? Double(VocalSeparator.sampleRate))
        let box = AudioRenderBox(separator: separator, sampleRate: sampleRate, debugRecorder: debugRecorder)
        renderBox = box

        let status = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggregateDeviceID,
            queue,
            AudioIOCallbackFactory.make(renderBox: box)
        )
        try checkOSStatus(status, "Create IO proc")
        procID = newProcID
        try checkOSStatus(AudioDeviceStart(aggregateDeviceID, procID), "Start aggregate device")
    }

    private func cleanup() {
        if originalDefaultOutputID != .unknown {
            try? AudioObjectID.systemObject.setDefaultOutputDevice(originalDefaultOutputID)
        }

        if aggregateDeviceID != .unknown, let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        procID = nil

        originalDefaultOutputID = .unknown

        if aggregateDeviceID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = .unknown

        if #available(macOS 14.2, *), tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = .unknown
        tapDescription = nil
        separator?.reset()
        separator = nil
        renderBox = nil
    }
}
