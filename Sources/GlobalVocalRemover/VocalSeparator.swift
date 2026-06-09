import Accelerate
import Foundation
import OnnxRuntimeBindings

final class VocalSeparator {
    static let sampleRate: UInt32 = 44_100
    static let channels = 2
    static let nFFT = 1024
    static let hopLength = 512
    static let dimF = 384
    static let dimT = 64
    static let overlap = nFFT / 2
    static let inferenceChunkFrames = hopLength * (dimT - 1)
    static let outputChunkFrames = inferenceChunkFrames - 2 * overlap

    private let inferenceSession: ORTVocalInferenceSession
    private let inputName: String
    private let outputName: String
    private let window: [Float]
    private let forwardDFT: vDSP_DFT_Setup
    private let inverseDFT: vDSP_DFT_Setup
    private var inputBuffer: [Float] = []
    private var outputBuffer: [Float] = []

    init(useCoreML: Bool = true) throws {
        guard let modelURL = Self.modelURL() else {
            throw SeparatorError.missingModel
        }

        inferenceSession = try ORTVocalInferenceSession(modelURL: modelURL, useCoreML: useCoreML)
        inputName = inferenceSession.inputName
        outputName = inferenceSession.outputName

        window = (0..<Self.nFFT).map { index in
            0.5 * (1.0 - cosf(2.0 * .pi * Float(index) / Float(Self.nFFT)))
        }

        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.nFFT), .INVERSE)
        else {
            throw SeparatorError.dftSetupFailed
        }
        forwardDFT = forward
        inverseDFT = inverse
    }

    private static func modelURL() -> URL? {
        if let appBundleURL = Bundle.main.resourceURL?.appendingPathComponent(
            "GlobalVocalRemover_GlobalVocalRemover.bundle/Resources/Models/all_rt.onnx"),
            FileManager.default.fileExists(atPath: appBundleURL.path)
        {
            return appBundleURL
        }

        return Bundle.module.url(
            forResource: "all_rt",
            withExtension: "onnx",
            subdirectory: "Resources/Models"
        )
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardDFT)
        vDSP_DFT_DestroySetup(inverseDFT)
    }

    func reset() {
        inputBuffer.removeAll(keepingCapacity: true)
        outputBuffer.removeAll(keepingCapacity: true)
    }

    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int, channels: Int, sampleRate: UInt32) {
        let sampleCount = frames * channels
        guard channels == Self.channels, sampleRate == Self.sampleRate else {
            output.update(from: input, count: sampleCount)
            reset()
            return
        }

        inputBuffer.append(contentsOf: UnsafeBufferPointer(start: input, count: sampleCount))
        while inputBuffer.count >= Self.outputChunkFrames * Self.channels {
            let chunkSamples = Self.outputChunkFrames * Self.channels
            let chunk = Array(inputBuffer.prefix(chunkSamples))
            inputBuffer.removeFirst(chunkSamples)
            if let processed = try? processChunk(chunk) {
                outputBuffer.append(contentsOf: processed)
            } else {
                outputBuffer.append(contentsOf: chunk)
            }
        }

        if outputBuffer.count >= sampleCount {
            output.update(from: outputBuffer, count: sampleCount)
            outputBuffer.removeFirst(sampleCount)
        } else {
            output.update(from: input, count: sampleCount)
        }
    }

    private func processChunk(_ chunk: [Float]) throws -> [Float] {
        var padded = [Float](repeating: 0, count: Self.inferenceChunkFrames * Self.channels)
        let offset = Self.overlap * Self.channels
        padded.replaceSubrange(offset..<(offset + chunk.count), with: chunk)

        let (left, right) = deinterleave(padded)
        let stft = stft(left: left, right: right)
        let inputTensor = makeModelInput(stft: stft)
        let outputTensor = try inferenceSession.run(input: inputTensor)

        let vocal = istft(outputTensor: outputTensor)
        var instrumental = [Float](repeating: 0, count: Self.outputChunkFrames * Self.channels)
        var outIndex = 0
        for frame in Self.overlap..<(Self.overlap + Self.outputChunkFrames) {
            instrumental[outIndex] = (left[frame] - vocal.left[frame]).clampedAudio
            instrumental[outIndex + 1] = (right[frame] - vocal.right[frame]).clampedAudio
            outIndex += 2
        }
        return instrumental
    }

    private func deinterleave(_ samples: [Float]) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: Self.inferenceChunkFrames)
        var right = [Float](repeating: 0, count: Self.inferenceChunkFrames)
        for frame in 0..<Self.inferenceChunkFrames {
            left[frame] = samples[frame * 2]
            right[frame] = samples[frame * 2 + 1]
        }
        return (left, right)
    }

    private func stft(left: [Float], right: [Float]) -> [(real: [Float], imag: [Float])] {
        var result: [(real: [Float], imag: [Float])] = []
        result.reserveCapacity(Self.channels * Self.dimT)

        for channel in [left, right] {
            for frameIndex in 0..<Self.dimT {
                let frameStart = frameIndex * Self.hopLength - Self.overlap
                var realIn = [Float](repeating: 0, count: Self.nFFT)
                let imagIn = [Float](repeating: 0, count: Self.nFFT)
                for index in 0..<Self.nFFT {
                    let source = frameStart + index
                    if source >= 0 && source < channel.count {
                        realIn[index] = channel[source] * window[index]
                    }
                }
                var realOut = [Float](repeating: 0, count: Self.nFFT)
                var imagOut = [Float](repeating: 0, count: Self.nFFT)
                vDSP_DFT_Execute(forwardDFT, realIn, imagIn, &realOut, &imagOut)
                result.append((realOut, imagOut))
            }
        }

        return result
    }

    private func makeModelInput(stft: [(real: [Float], imag: [Float])]) -> [Float] {
        var tensor = [Float](repeating: 0, count: 4 * Self.dimF * Self.dimT)

        for channel in 0..<Self.channels {
            for frame in 0..<Self.dimT {
                let spec = stft[channel * Self.dimT + frame]
                for freq in 0..<Self.dimF {
                    let reIndex = (channel * 2) * Self.dimF * Self.dimT + freq * Self.dimT + frame
                    let imIndex = (channel * 2 + 1) * Self.dimF * Self.dimT + freq * Self.dimT + frame
                    tensor[reIndex] = spec.real[freq]
                    tensor[imIndex] = spec.imag[freq]
                }
            }
        }

        return tensor
    }

    private func istft(outputTensor pointer: [Float]) -> (left: [Float], right: [Float]) {
        var waveforms = [[Float]]()
        waveforms.reserveCapacity(Self.channels)
        let vocalIndex = 3
        let sourceStride = 4 * Self.dimF * Self.dimT
        let channelStride = Self.dimF * Self.dimT

        for channel in 0..<Self.channels {
            var output = [Float](repeating: 0, count: Self.nFFT + Self.hopLength * (Self.dimT - 1))
            var winSum = [Float](repeating: 0, count: output.count)

            for frame in 0..<Self.dimT {
                var realIn = [Float](repeating: 0, count: Self.nFFT)
                var imagIn = [Float](repeating: 0, count: Self.nFFT)

                for freq in 0..<Self.nFFT / 2 + 1 {
                    let re: Float
                    let im: Float
                    if freq < Self.dimF {
                        let base = vocalIndex * sourceStride + channel * 2 * channelStride + freq * Self.dimT + frame
                        re = pointer[base]
                        im = pointer[base + channelStride]
                    } else {
                        re = 0
                        im = 0
                    }
                    realIn[freq] = re
                    imagIn[freq] = im
                }
                for freq in 1..<(Self.nFFT / 2) {
                    realIn[Self.nFFT - freq] = realIn[freq]
                    imagIn[Self.nFFT - freq] = -imagIn[freq]
                }

                var realOut = [Float](repeating: 0, count: Self.nFFT)
                var imagOut = [Float](repeating: 0, count: Self.nFFT)
                vDSP_DFT_Execute(inverseDFT, realIn, imagIn, &realOut, &imagOut)

                let start = frame * Self.hopLength
                for index in 0..<Self.nFFT {
                    let sample = realOut[index] / Float(Self.nFFT)
                    let w = window[index]
                    output[start + index] += sample * w
                    winSum[start + index] += w * w
                }
            }

            for index in output.indices where winSum[index] > 1e-8 {
                output[index] /= winSum[index]
            }
            waveforms.append(Array(output[Self.overlap..<(output.count - Self.overlap)]))
        }

        return (waveforms[0], waveforms[1])
    }
}

enum SeparatorError: Error, LocalizedError {
    case missingModel
    case invalidModelInterface
    case dftSetupFailed

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "Missing Resources/Models/all_rt.onnx."
        case .invalidModelInterface:
            return "The ONNX model does not expose the expected tensor input/output."
        case .dftSetupFailed:
            return "Failed to initialize Accelerate DFT."
        }
    }
}

private extension Float {
    var clampedAudio: Float {
        min(1.0, max(-1.0, self))
    }
}
