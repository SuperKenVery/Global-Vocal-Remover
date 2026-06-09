import CoreFoundation
import Darwin
import Foundation

enum AudioCapturePermissionError: Error, LocalizedError {
    case denied

    var errorDescription: String? {
        switch self {
        case .denied:
            return "System audio capture permission was denied."
        }
    }
}

@MainActor
enum AudioCapturePermission {
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (
        CFString, CFDictionary?, @escaping (Bool) -> Void
    ) -> Void

    static func requestIfNeeded(timeout: TimeInterval = 30) throws {
        guard let preflight = preflightFunction else {
            return
        }

        let service = "kTCCServiceAudioCapture" as CFString
        let status = preflight(service, nil)
        if status == 0 {
            return
        }
        if status == 1 {
            throw AudioCapturePermissionError.denied
        }

        guard let request = requestFunction else {
            return
        }

        var granted: Bool?
        request(service, nil) { value in
            granted = value
        }

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while granted == nil && CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }

        if granted != true {
            throw AudioCapturePermissionError.denied
        }
    }

    private static let apiHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightFunction: PreflightFunction? = {
        guard let apiHandle, let symbol = dlsym(apiHandle, "TCCAccessPreflight") else {
            return nil
        }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let apiHandle, let symbol = dlsym(apiHandle, "TCCAccessRequest") else {
            return nil
        }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()
}
