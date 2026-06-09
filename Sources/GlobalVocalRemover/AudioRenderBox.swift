import AudioToolbox
import Atomics
import Foundation

final class AudioRenderBox: @unchecked Sendable {
    private let processingPipeline: AsyncVocalRemovalPipeline
    private let debugRecorder: AudioDebugRecorder?

    init(separator: VocalSeparator, sampleRate: UInt32, debugRecorder: AudioDebugRecorder? = nil) {
        processingPipeline = AsyncVocalRemovalPipeline(separator: separator, sampleRate: sampleRate)
        self.debugRecorder = debugRecorder
    }

    deinit {
        stop()
    }

    func stop() {
        processingPipeline.stop()
    }

    func render(
        inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        debugRecorder?.recordLayouts(input: inputs, output: outputs)

        let inputBuffers = stereoInputBuffers(inputs: inputs, routedTo: outputs)
        let interleavedInput = debugRecorder == nil ? nil : readStereoInterleaved(from: inputBuffers)
        if let interleavedInput {
            debugRecorder?.recordCapture(interleavedInput)
        } else {
            debugRecorder?.recordUnreadableInput(inputs)
        }

        guard let sampleCount = stereoSampleCount(from: inputBuffers),
            processingPipeline.enqueue(inputBuffers: inputBuffers)
        else {
            debugRecorder?.recordBypassCallback()
            let output = passThrough(
                inputs: inputs, outputs: outputs, knownInterleavedInput: interleavedInput)
            if let output {
                debugRecorder?.recordProcessed(output)
            }
            return
        }
        debugRecorder?.recordModelCallback()

        guard processingPipeline.writeOutput(to: outputs, sampleCount: sampleCount) else {
            debugRecorder?.recordBypassCallback()
            let output = passThrough(
                inputs: inputs,
                outputs: outputs,
                knownInterleavedInput: interleavedInput
            )
            if let output {
                debugRecorder?.recordProcessed(output)
            }
            return
        }

        if let debugRecorder, let output = readStereoInterleaved(from: Array(outputs)) {
            debugRecorder.recordProcessed(output)
        }
    }

    private func stereoInputBuffers(
        inputs: UnsafeMutableAudioBufferListPointer,
        routedTo outputs: UnsafeMutableAudioBufferListPointer
    ) -> [AudioBuffer] {
        let routed = routedInputBuffers(inputs, routedTo: outputs)
        if stereoSampleCount(from: routed) != nil {
            return routed
        }

        if outputs.count == 1,
            outputs[0].mNumberChannels == 2
        {
            return lastStereoInputBuffers(inputs)
        }

        return routed
    }

    private func stereoSampleCount(from buffers: [AudioBuffer]) -> Int? {
        if buffers.count >= 1, buffers[0].mNumberChannels == 2,
            buffers[0].mData != nil
        {
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / 2
            return frames * VocalSeparator.channels
        }

        if buffers.count >= 2,
            buffers[0].mNumberChannels == 1,
            buffers[1].mNumberChannels == 1,
            buffers[0].mData != nil,
            buffers[1].mData != nil
        {
            let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
            return min(leftFrames, rightFrames) * VocalSeparator.channels
        }

        return nil
    }

    private func readStereoInterleaved(
        inputs: UnsafeMutableAudioBufferListPointer,
        routedTo outputs: UnsafeMutableAudioBufferListPointer
    ) -> [Float]? {
        if let interleaved = readStereoInterleaved(
            from: routedInputBuffers(inputs, routedTo: outputs))
        {
            return interleaved
        }

        if outputs.count == 1,
            outputs[0].mNumberChannels == 2,
            let interleaved = readStereoInterleaved(from: lastStereoInputBuffers(inputs))
        {
            return interleaved
        }

        return nil
    }

    private func readStereoInterleaved(from buffers: [AudioBuffer]) -> [Float]? {
        if buffers.count >= 1, buffers[0].mNumberChannels == 2,
            let data = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        {
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / 2
            return Array(UnsafeBufferPointer(start: data, count: frames * 2))
        }

        if buffers.count >= 2,
            buffers[0].mNumberChannels == 1,
            buffers[1].mNumberChannels == 1,
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
            let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        {
            let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
            let frames = min(leftFrames, rightFrames)
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames {
                interleaved[frame * 2] = left[frame]
                interleaved[frame * 2 + 1] = right[frame]
            }
            return interleaved
        }

        return nil
    }

    private func routedInputBuffers(
        _ inputs: UnsafeMutableAudioBufferListPointer,
        routedTo outputs: UnsafeMutableAudioBufferListPointer
    ) -> [AudioBuffer] {
        guard inputs.count > 0, outputs.count > 0 else {
            return []
        }

        // Aggregate devices may prepend physical input buffers before the tap output.
        // The tap buffers line up with output buffers at the end of the input list.
        let startIndex = inputs.count > outputs.count ? inputs.count - outputs.count : 0
        let count = min(outputs.count, inputs.count - startIndex)
        guard count > 0 else {
            return []
        }

        return (0..<count).map { inputs[startIndex + $0] }
    }

    private func lastStereoInputBuffers(_ inputs: UnsafeMutableAudioBufferListPointer)
        -> [AudioBuffer]
    {
        if inputs.count >= 1, inputs[inputs.count - 1].mNumberChannels == 2 {
            return [inputs[inputs.count - 1]]
        }

        if inputs.count >= 2,
            inputs[inputs.count - 2].mNumberChannels == 1,
            inputs[inputs.count - 1].mNumberChannels == 1
        {
            return [inputs[inputs.count - 2], inputs[inputs.count - 1]]
        }

        return []
    }

    private func writeStereoInterleaved(
        _ interleaved: [Float],
        outputs: UnsafeMutableAudioBufferListPointer
    ) -> Bool {
        let frames = interleaved.count / 2

        if outputs.count >= 1,
            outputs[0].mNumberChannels == 2,
            let data = outputs[0].mData?.assumingMemoryBound(to: Float.self),
            Int(outputs[0].mDataByteSize) >= frames * 2 * MemoryLayout<Float>.size
        {
            data.update(from: interleaved, count: frames * 2)
            return true
        }

        if outputs.count >= 2,
            outputs[0].mNumberChannels == 1,
            outputs[1].mNumberChannels == 1,
            let left = outputs[0].mData?.assumingMemoryBound(to: Float.self),
            let right = outputs[1].mData?.assumingMemoryBound(to: Float.self),
            Int(outputs[0].mDataByteSize) >= frames * MemoryLayout<Float>.size,
            Int(outputs[1].mDataByteSize) >= frames * MemoryLayout<Float>.size
        {
            for frame in 0..<frames {
                left[frame] = interleaved[frame * 2]
                right[frame] = interleaved[frame * 2 + 1]
            }
            return true
        }

        return false
    }

    private func passThrough(
        inputs: UnsafeMutableAudioBufferListPointer,
        outputs: UnsafeMutableAudioBufferListPointer,
        knownInterleavedInput: [Float]? = nil
    ) -> [Float]? {
        if let interleaved = knownInterleavedInput
            ?? readStereoInterleaved(
                inputs: inputs,
                routedTo: outputs
            ),
            writeStereoInterleaved(interleaved, outputs: outputs)
        {
            return interleaved
        }

        for index in 0..<outputs.count {
            let inputIndex = routedInputIndex(
                outputIndex: index,
                inputCount: inputs.count,
                outputCount: outputs.count
            )
            guard inputIndex < inputs.count,
                let input = inputs[inputIndex].mData,
                let output = outputs[index].mData
            else {
                if let output = outputs[index].mData {
                    memset(output, 0, Int(outputs[index].mDataByteSize))
                }
                continue
            }

            memcpy(
                output, input,
                min(Int(inputs[inputIndex].mDataByteSize), Int(outputs[index].mDataByteSize)))
        }

        return readStereoInterleaved(from: Array(outputs))
    }

    private func routedInputIndex(outputIndex: Int, inputCount: Int, outputCount: Int) -> Int {
        if inputCount > outputCount {
            return inputCount - outputCount + outputIndex
        }
        return outputIndex
    }
}

enum AudioIOCallbackFactory {
    static func make(renderBox: AudioRenderBox) -> AudioDeviceIOBlock {
        { _, inputData, _, outputData, _ in
            renderBox.render(inputData: inputData, outputData: outputData)
        }
    }
}

private final class AsyncVocalRemovalPipeline: @unchecked Sendable {
    private static let queueFrames = VocalSeparator.sampleRate * 4
    private static let maxWorkerBatchSamples = VocalSeparator.outputChunkFrames * VocalSeparator.channels

    private let separator: VocalSeparator
    private let sampleRate: UInt32
    private let inputResampler: StereoLinearResampler?
    private let outputResampler: StereoLinearResampler?
    private let inputQueue: SPSCSampleRing
    private let outputQueue: SPSCSampleRing
    private let semaphore = DispatchSemaphore(value: 0)
    private let running = ManagedAtomic(true)
    private var pendingDeviceOutput: [Float] = []
    private var worker: Thread?

    init(separator: VocalSeparator, sampleRate: UInt32) {
        self.separator = separator
        self.sampleRate = sampleRate
        if sampleRate == VocalSeparator.sampleRate {
            inputResampler = nil
            outputResampler = nil
        } else {
            inputResampler = StereoLinearResampler(
                inputRate: sampleRate,
                outputRate: VocalSeparator.sampleRate
            )
            outputResampler = StereoLinearResampler(
                inputRate: VocalSeparator.sampleRate,
                outputRate: sampleRate
            )
        }

        let queueSamples = Int(Self.queueFrames) * VocalSeparator.channels
        inputQueue = SPSCSampleRing(capacity: queueSamples)
        outputQueue = SPSCSampleRing(capacity: queueSamples)

        worker = Thread { [weak self] in
            self?.runWorker()
        }
        worker?.qualityOfService = .userInitiated
        worker?.name = "GlobalVocalRemover.AsyncVocalRemoval"
        worker?.start()
    }

    deinit {
        stop()
    }

    func stop() {
        running.store(false, ordering: .releasing)
        semaphore.signal()
    }

    func enqueue(inputBuffers: [AudioBuffer]) -> Bool {
        if inputQueue.writeStereo(from: inputBuffers) != nil {
            semaphore.signal()
            return true
        }
        return false
    }

    func writeOutput(to outputs: UnsafeMutableAudioBufferListPointer, sampleCount: Int) -> Bool {
        outputQueue.readStereo(to: outputs, sampleCount: sampleCount)
    }

    private func runWorker() {
        while running.load(ordering: .acquiring) {
            semaphore.wait()
            while running.load(ordering: .relaxed) {
                let input = inputQueue.readAvailable(maxSamples: Self.maxWorkerBatchSamples)
                guard !input.isEmpty else { break }
                let output = process(input)
                _ = outputQueue.write(output)
            }
        }
    }

    private func process(_ interleavedInput: [Float]) -> [Float] {
        if sampleRate == VocalSeparator.sampleRate {
            return processAtModelRate(interleavedInput)
        }
        return processViaResamplers(interleavedInput)
    }

    private func processAtModelRate(_ interleavedInput: [Float]) -> [Float] {
        let frames = interleavedInput.count / VocalSeparator.channels
        var interleavedOutput = [Float](repeating: 0, count: interleavedInput.count)
        separator.process(
            input: interleavedInput,
            output: &interleavedOutput,
            frames: frames,
            channels: VocalSeparator.channels,
            sampleRate: VocalSeparator.sampleRate
        )
        return interleavedOutput
    }

    private func processViaResamplers(_ interleavedInput: [Float]) -> [Float] {
        guard let inputResampler, let outputResampler else {
            return interleavedInput
        }

        let modelInput = inputResampler.process(interleavedInput)
        if !modelInput.isEmpty {
            let modelFrames = modelInput.count / VocalSeparator.channels
            var modelOutput = [Float](repeating: 0, count: modelInput.count)
            separator.process(
                input: modelInput,
                output: &modelOutput,
                frames: modelFrames,
                channels: VocalSeparator.channels,
                sampleRate: VocalSeparator.sampleRate
            )
            pendingDeviceOutput.append(contentsOf: outputResampler.process(modelOutput))
        }

        let targetSamples = interleavedInput.count
        if pendingDeviceOutput.count >= targetSamples {
            let output = Array(pendingDeviceOutput.prefix(targetSamples))
            pendingDeviceOutput.removeFirst(targetSamples)
            return output
        }

        var output = pendingDeviceOutput
        pendingDeviceOutput.removeAll(keepingCapacity: true)
        output.append(
            contentsOf: interleavedInput.dropFirst(output.count).prefix(targetSamples - output.count)
        )
        if output.count < targetSamples {
            output.append(contentsOf: repeatElement(Float(0), count: targetSamples - output.count))
        }
        return output
    }
}

private final class SPSCSampleRing: @unchecked Sendable {
    private var storage: [Float]
    private let capacity: Int
    private let readIndex = ManagedAtomic(0)
    private let writeIndex = ManagedAtomic(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = [Float](repeating: 0, count: capacity)
    }

    func write(_ samples: [Float]) -> Bool {
        let count = samples.count
        guard reserveWrite(count) else { return false }

        let write = writeIndex.load(ordering: .relaxed)
        for index in 0..<count {
            storage[(write + index) % capacity] = samples[index]
        }
        writeIndex.store(write + count, ordering: .releasing)
        return true
    }

    func writeStereo(from buffers: [AudioBuffer]) -> Int? {
        if buffers.count >= 1, buffers[0].mNumberChannels == 2,
            let data = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        {
            let sampleCount = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            guard reserveWrite(sampleCount) else { return nil }

            let write = writeIndex.load(ordering: .relaxed)
            for index in 0..<sampleCount {
                storage[(write + index) % capacity] = data[index]
            }
            writeIndex.store(write + sampleCount, ordering: .releasing)
            return sampleCount
        }

        if buffers.count >= 2,
            buffers[0].mNumberChannels == 1,
            buffers[1].mNumberChannels == 1,
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
            let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        {
            let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
            let frames = min(leftFrames, rightFrames)
            let sampleCount = frames * VocalSeparator.channels
            guard reserveWrite(sampleCount) else { return nil }

            let write = writeIndex.load(ordering: .relaxed)
            for frame in 0..<frames {
                storage[(write + frame * 2) % capacity] = left[frame]
                storage[(write + frame * 2 + 1) % capacity] = right[frame]
            }
            writeIndex.store(write + sampleCount, ordering: .releasing)
            return sampleCount
        }

        return nil
    }

    func readStereo(to outputs: UnsafeMutableAudioBufferListPointer, sampleCount: Int) -> Bool {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard write - read >= sampleCount else { return false }

        let frames = sampleCount / VocalSeparator.channels
        if outputs.count >= 1,
            outputs[0].mNumberChannels == 2,
            let data = outputs[0].mData?.assumingMemoryBound(to: Float.self),
            Int(outputs[0].mDataByteSize) >= sampleCount * MemoryLayout<Float>.size
        {
            for index in 0..<sampleCount {
                data[index] = storage[(read + index) % capacity]
            }
            readIndex.store(read + sampleCount, ordering: .releasing)
            return true
        }

        if outputs.count >= 2,
            outputs[0].mNumberChannels == 1,
            outputs[1].mNumberChannels == 1,
            let left = outputs[0].mData?.assumingMemoryBound(to: Float.self),
            let right = outputs[1].mData?.assumingMemoryBound(to: Float.self),
            Int(outputs[0].mDataByteSize) >= frames * MemoryLayout<Float>.size,
            Int(outputs[1].mDataByteSize) >= frames * MemoryLayout<Float>.size
        {
            for frame in 0..<frames {
                left[frame] = storage[(read + frame * 2) % capacity]
                right[frame] = storage[(read + frame * 2 + 1) % capacity]
            }
            readIndex.store(read + sampleCount, ordering: .releasing)
            return true
        }

        return false
    }

    func readAvailable(maxSamples: Int) -> [Float] {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let count = min(maxSamples, write - read)
        guard count > 0 else { return [] }

        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            output[index] = storage[(read + index) % capacity]
        }
        readIndex.store(read + count, ordering: .releasing)
        return output
    }

    private func reserveWrite(_ count: Int) -> Bool {
        guard count <= capacity else { return false }

        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        return capacity - (write - read) >= count
    }
}
