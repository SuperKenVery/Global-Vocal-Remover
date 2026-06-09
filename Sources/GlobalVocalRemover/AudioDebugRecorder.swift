import AudioToolbox
import Foundation

final class AudioDebugRecorder: @unchecked Sendable {
    let directory: URL
    let captureURL: URL
    let processedURL: URL
    let metadataURL: URL

    private let captureHandle: FileHandle
    private let processedHandle: FileHandle
    private let sampleRate: UInt32
    private var captureFrames: Int = 0
    private var processedFrames: Int = 0
    private var unreadableInputCallbacks: Int = 0
    private var modelCallbacks: Int = 0
    private var bypassCallbacks: Int = 0
    private var firstInputLayout: [[String: UInt32]]?
    private var firstOutputLayout: [[String: UInt32]]?
    private var firstUnreadableLayout: [[String: UInt32]]?

    init(directory: URL, sampleRate: UInt32) throws {
        self.directory = directory
        self.sampleRate = sampleRate
        captureURL = directory.appendingPathComponent("capture.f32le")
        processedURL = directory.appendingPathComponent("processed.f32le")
        metadataURL = directory.appendingPathComponent("debug-capture.json")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: captureURL.path, contents: nil)
        FileManager.default.createFile(atPath: processedURL.path, contents: nil)
        captureHandle = try FileHandle(forWritingTo: captureURL)
        processedHandle = try FileHandle(forWritingTo: processedURL)
    }

    func recordCapture(_ interleavedStereo: [Float]) {
        write(interleavedStereo, to: captureHandle)
        captureFrames += interleavedStereo.count / VocalSeparator.channels
    }

    func recordProcessed(_ interleavedStereo: [Float]) {
        write(interleavedStereo, to: processedHandle)
        processedFrames += interleavedStereo.count / VocalSeparator.channels
    }

    func recordModelCallback() {
        modelCallbacks += 1
    }

    func recordBypassCallback() {
        bypassCallbacks += 1
    }

    func recordLayouts(
        input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer
    ) {
        if firstInputLayout == nil {
            firstInputLayout = layout(input)
        }
        if firstOutputLayout == nil {
            firstOutputLayout = layout(output)
        }
    }

    func recordUnreadableInput(_ buffers: UnsafeMutableAudioBufferListPointer) {
        print("Met unreadable input")
        unreadableInputCallbacks += 1
        guard firstUnreadableLayout == nil else { return }
        firstUnreadableLayout = layout(buffers)
    }

    func close() throws {
        try captureHandle.close()
        try processedHandle.close()

        let metadata = DebugCaptureMetadata(
            sampleRate: sampleRate,
            channels: VocalSeparator.channels,
            sampleFormat: "float32 little-endian interleaved stereo",
            captureFile: captureURL.lastPathComponent,
            processedFile: processedURL.lastPathComponent,
            captureFrames: captureFrames,
            processedFrames: processedFrames,
            unreadableInputCallbacks: unreadableInputCallbacks,
            modelCallbacks: modelCallbacks,
            bypassCallbacks: bypassCallbacks,
            firstInputLayout: firstInputLayout,
            firstOutputLayout: firstOutputLayout,
            firstUnreadableInputLayout: firstUnreadableLayout
        )
        let data = try JSONEncoder.pretty.encode(metadata)
        try data.write(to: metadataURL)
    }

    private func write(_ values: [Float], to handle: FileHandle) {
        values.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            let bytes = UnsafeRawBufferPointer(
                start: baseAddress, count: pointer.count * MemoryLayout<Float>.size)
            handle.write(Data(bytes))
        }
    }

    private func layout(_ buffers: UnsafeMutableAudioBufferListPointer) -> [[String: UInt32]] {
        buffers.map {
            [
                "channels": $0.mNumberChannels,
                "byteSize": $0.mDataByteSize,
            ]
        }
    }
}

private struct DebugCaptureMetadata: Encodable {
    let sampleRate: UInt32
    let channels: Int
    let sampleFormat: String
    let captureFile: String
    let processedFile: String
    let captureFrames: Int
    let processedFrames: Int
    let unreadableInputCallbacks: Int
    let modelCallbacks: Int
    let bypassCallbacks: Int
    let firstInputLayout: [[String: UInt32]]?
    let firstOutputLayout: [[String: UInt32]]?
    let firstUnreadableInputLayout: [[String: UInt32]]?
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
