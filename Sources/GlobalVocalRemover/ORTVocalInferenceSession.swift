import Foundation
import OnnxRuntimeBindings

final class ORTVocalInferenceSession {
    let inputName: String
    let outputName: String

    private let env: ORTEnv
    private let session: ORTSession
    private let inputShape: [NSNumber] = [1, 4, 384, 64]
    private let outputShape: [NSNumber] = [1, 4, 4, 384, 64]
    private let outputElementCount = 1 * 4 * 4 * 384 * 64

    init(modelURL: URL, useCoreML: Bool = true) throws {
        env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)

        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        try options.setIntraOpNumThreads(1)
        try options.setLogSeverityLevel(ORTLoggingLevel.warning)

        if useCoreML && ORTIsCoreMLExecutionProviderAvailable() {
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.enableOnSubgraphs = true
            coreMLOptions.onlyAllowStaticInputShapes = true
            coreMLOptions.createMLProgram = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }

        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = try session.inputNames().first ?? "input"
        outputName = try session.outputNames().first ?? "output"
    }

    func run(input: [Float]) throws -> [Float] {
        let inputData = mutableData(copying: input)
        let inputValue = try ORTValue(
            tensorData: inputData,
            elementType: ORTTensorElementDataType.float,
            shape: inputShape
        )

        let outputs = try session.run(
            withInputs: [inputName: inputValue],
            outputNames: Set([outputName]),
            runOptions: nil
        )

        guard let outputValue = outputs[outputName] else {
            throw SeparatorError.invalidModelInterface
        }
        let outputData = try outputValue.tensorData()

        let count = outputData.length / MemoryLayout<Float>.size
        guard count == outputElementCount else {
            throw SeparatorError.invalidModelInterface
        }

        let pointer = outputData.bytes.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func mutableData(copying floats: [Float]) -> NSMutableData {
        let byteCount = floats.count * MemoryLayout<Float>.size
        let data = NSMutableData(length: byteCount)!
        data.mutableBytes.assumingMemoryBound(to: Float.self).initialize(from: floats, count: floats.count)
        return data
    }
}
