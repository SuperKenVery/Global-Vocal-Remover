# Global Vocal Remover

Native macOS menu bar app that captures global system audio with Core Audio Process Tap and runs an RT-DTT vocal-removal ONNX model through ONNX Runtime with the CoreML Execution Provider.

## Build

The ONNX model is bundled at `Sources/GlobalVocalRemover/Resources/Models/all_rt.onnx`.

```sh
./scripts/build_app.sh
```

Run:

```sh
open .build/GlobalVocalRemover.app
```

## Verify

Run the CPU fallback path:

```sh
.build/release/GlobalVocalRemover --self-test-cpu
```

Run ONNX Runtime with CoreML EP:

```sh
.build/release/GlobalVocalRemover --self-test
```

## Debug Capture

Capture the system tap input and the rendered output for a fixed duration:

```sh
.build/release/GlobalVocalRemover --debug-run --duration 10 --debug-dir /tmp/gvr-debug
```

Analyze the raw float32 stereo files:

```sh
uv run --python .uv-coreml/bin/python scripts/analyze_debug_capture.py /tmp/gvr-debug
```

The debug directory contains:

- `capture.f32le`: system audio captured by the Core Audio process tap.
- `processed.f32le`: audio written by the app to the aggregate output callback.
- `debug-capture.json`: sample rate, callback counts, and first input/output buffer layout.

## Notes

- The separator model expects 44.1 kHz stereo audio with 31,232-frame output chunks, matching the reference RT-DTT implementation.
- Device rates such as 48 kHz are handled by a software stereo resampler around the 44.1 kHz model path.
- ONNX Runtime/CoreML currently partitions this model: most nodes run on CoreML and shape-related nodes remain on CPU.
- Current processing is a first native prototype. Inference should be moved off the HAL callback thread behind a latency buffer before using it as a daily driver.
