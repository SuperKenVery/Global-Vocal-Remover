import AudioToolbox
import Foundation

final class AudioRenderBox: @unchecked Sendable {
    private let separator: VocalSeparator
    private let sampleRate: UInt32
    private let debugRecorder: AudioDebugRecorder?
    private let inputResampler: StereoLinearResampler?
    private let outputResampler: StereoLinearResampler?
    private var pendingDeviceOutput: [Float] = []

    init(separator: VocalSeparator, sampleRate: UInt32, debugRecorder: AudioDebugRecorder? = nil) {
        self.separator = separator
        self.sampleRate = sampleRate
        self.debugRecorder = debugRecorder
        if sampleRate == VocalSeparator.sampleRate {
            inputResampler = nil
            outputResampler = nil
        } else {
            inputResampler = StereoLinearResampler(
                inputRate: sampleRate, outputRate: VocalSeparator.sampleRate)
            outputResampler = StereoLinearResampler(
                inputRate: VocalSeparator.sampleRate, outputRate: sampleRate)
        }
    }

    func render(
        inputData: UnsafePointer<AudioBufferList>, outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        debugRecorder?.recordLayouts(input: inputs, output: outputs)
        let interleavedInput = readStereoInterleaved(inputs: inputs, routedTo: outputs)
        if let interleavedInput {
            debugRecorder?.recordCapture(interleavedInput)
        } else {
            debugRecorder?.recordUnreadableInput(inputs)
        }

        guard let interleavedInput else {
            debugRecorder?.recordBypassCallback()
            let output = passThrough(
                inputs: inputs, outputs: outputs, knownInterleavedInput: interleavedInput)
            if let output {
                debugRecorder?.recordProcessed(output)
            }
            return
        }
        debugRecorder?.recordModelCallback()

        // let interleavedOutput: [Float]
        // if sampleRate == VocalSeparator.sampleRate {
        //     interleavedOutput = processAtModelRate(interleavedInput)
        // } else {
        //     interleavedOutput = processViaResamplers(interleavedInput)
        // }

        // if writeStereoInterleaved(interleavedOutput, outputs: outputs) {
        //     debugRecorder?.recordProcessed(interleavedOutput)
        // } else {
        // print("Failed to write output, passing through instead")
        let output = passThrough(
            inputs: inputs, outputs: outputs, knownInterleavedInput: interleavedInput)
        if let output {
            debugRecorder?.recordProcessed(output)
        } else {
            print("Failed to pass through output")
        }
        // }
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
            contentsOf: interleavedInput.dropFirst(output.count).prefix(
                targetSamples - output.count))
        if output.count < targetSamples {
            output.append(contentsOf: repeatElement(Float(0), count: targetSamples - output.count))
        }
        return output
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
