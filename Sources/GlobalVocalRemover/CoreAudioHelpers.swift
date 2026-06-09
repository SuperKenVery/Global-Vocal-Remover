import AudioToolbox
import CoreAudio
import CoreFoundation
import Foundation

enum CoreAudioError: Error, LocalizedError {
    case osStatus(OSStatus, String)
    case missingDefaultOutput
    case missingDeviceUID

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, message):
            return "\(message) (OSStatus \(status))"
        case .missingDefaultOutput:
            return "Could not read the current default output device."
        case .missingDeviceUID:
            return "Could not read the current output device UID."
        }
    }
}

func checkOSStatus(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(status, message) }
}

extension AudioObjectID {
    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }
    static var unknown: AudioObjectID { AudioObjectID(kAudioObjectUnknown) }

    func readDefaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &device), "Read default output")
        guard device != .unknown else { throw CoreAudioError.missingDefaultOutput }
        return device
    }

    func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDevice = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(AudioObjectSetPropertyData(self, &address, 0, nil, size, &mutableDevice), "Set default output")
    }

    func translatePIDToProcessObjectID(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutablePID = pid
        var processObject = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                self,
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &mutablePID,
                &size,
                &processObject
            ),
            "Translate PID to process object"
        )
        return processObject
    }

    func readDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<CFString>.size,
            alignment: MemoryLayout<CFString>.alignment
        )
        defer { storage.deallocate() }
        var size = UInt32(MemoryLayout<CFString>.size)
        try checkOSStatus(AudioObjectGetPropertyData(self, &address, 0, nil, &size, storage), "Read device UID")
        let value = storage.load(as: CFString.self) as String
        guard !value.isEmpty else { throw CoreAudioError.missingDeviceUID }
        return value
    }

    func readNominalSampleRate() throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        try checkOSStatus(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &rate), "Read sample rate")
        return rate
    }

    func isDeviceAlive() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isAlive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &isAlive)
        return status == noErr && isAlive != 0
    }

    func waitUntilReady(timeout: TimeInterval = 1.0, pollInterval: TimeInterval = 0.01) -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        while CFAbsoluteTimeGetCurrent() < deadline {
            if isDeviceAlive() {
                return true
            }
            CFRunLoopRunInMode(.defaultMode, pollInterval, false)
        }

        return false
    }
}
