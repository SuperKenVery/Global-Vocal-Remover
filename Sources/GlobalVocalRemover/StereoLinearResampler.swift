import Foundation

final class StereoLinearResampler {
    private let inputRate: Double
    private let outputRate: Double
    private var position = 0.0
    private var tailLeft: Float?
    private var tailRight: Float?

    init(inputRate: UInt32, outputRate: UInt32) {
        self.inputRate = Double(inputRate)
        self.outputRate = Double(outputRate)
    }

    func reset() {
        position = 0
        tailLeft = nil
        tailRight = nil
    }

    func process(_ interleavedStereo: [Float]) -> [Float] {
        let inputFrames = interleavedStereo.count / VocalSeparator.channels
        guard inputFrames > 0 else { return [] }

        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(inputFrames + 1)
        right.reserveCapacity(inputFrames + 1)

        if let tailLeft, let tailRight {
            left.append(tailLeft)
            right.append(tailRight)
        } else {
            position = 0
        }

        for frame in 0..<inputFrames {
            left.append(interleavedStereo[frame * 2])
            right.append(interleavedStereo[frame * 2 + 1])
        }

        let frameCount = left.count
        guard frameCount >= 2 else {
            tailLeft = left.last
            tailRight = right.last
            return []
        }

        let step = inputRate / outputRate
        var output = [Float]()
        output.reserveCapacity(Int(Double(inputFrames) * outputRate / inputRate + 4) * 2)

        while position < Double(frameCount - 1) {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            output.append(left[index] + (left[index + 1] - left[index]) * fraction)
            output.append(right[index] + (right[index + 1] - right[index]) * fraction)
            position += step
        }

        position -= Double(frameCount - 1)
        tailLeft = left.last
        tailRight = right.last
        return output
    }
}
