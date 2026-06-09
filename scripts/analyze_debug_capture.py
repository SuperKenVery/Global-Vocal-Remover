#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path

import numpy as np


def db(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-12))


def read_f32le_stereo(path: Path) -> np.ndarray:
    data = np.fromfile(path, dtype=np.float32)
    if data.size % 2:
        data = data[:-1]
    return data.reshape(-1, 2)


def metrics(name: str, audio: np.ndarray) -> dict[str, float]:
    if audio.size == 0:
        return {
            f"{name}_frames": 0,
            f"{name}_rms_dbfs": -240.0,
            f"{name}_mono_rms_dbfs": -240.0,
            f"{name}_peak_dbfs": -240.0,
            f"{name}_nonzero_ratio": 0.0,
        }

    mono = audio.mean(axis=1)
    return {
        f"{name}_frames": float(audio.shape[0]),
        f"{name}_rms_dbfs": db(float(np.sqrt(np.mean(audio * audio)))),
        f"{name}_mono_rms_dbfs": db(float(np.sqrt(np.mean(mono * mono)))),
        f"{name}_peak_dbfs": db(float(np.max(np.abs(audio)))),
        f"{name}_nonzero_ratio": float(np.count_nonzero(np.abs(audio) > 1e-8) / audio.size),
    }


def compare(capture: np.ndarray, processed: np.ndarray) -> dict[str, float]:
    frames = min(capture.shape[0], processed.shape[0])
    if frames == 0:
        return {}

    c = capture[:frames]
    p = processed[:frames]
    diff = p - c
    capture_rms = float(np.sqrt(np.mean(c * c)))
    processed_rms = float(np.sqrt(np.mean(p * p)))
    diff_rms = float(np.sqrt(np.mean(diff * diff)))
    corr = float(np.corrcoef(c.reshape(-1), p.reshape(-1))[0, 1])
    return {
        "processed_minus_capture_db": db(processed_rms) - db(capture_rms),
        "processed_vs_capture_diff_rms_dbfs": db(diff_rms),
        "capture_processed_corr": corr,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("debug_dir", type=Path)
    args = parser.parse_args()

    metadata_path = args.debug_dir / "debug-capture.json"
    metadata = json.loads(metadata_path.read_text())
    capture = read_f32le_stereo(args.debug_dir / metadata["captureFile"])
    processed = read_f32le_stereo(args.debug_dir / metadata["processedFile"])

    sample_rate = metadata["sampleRate"]
    print(f"sample_rate: {sample_rate}")
    print(f"capture_seconds: {capture.shape[0] / sample_rate:.3f}")
    print(f"processed_seconds: {processed.shape[0] / sample_rate:.3f}")
    print(f"unreadable_input_callbacks: {metadata['unreadableInputCallbacks']}")
    print(f"model_callbacks: {metadata.get('modelCallbacks', 0)}")
    print(f"bypass_callbacks: {metadata.get('bypassCallbacks', 0)}")
    if metadata.get("firstInputLayout"):
        print(f"first_input_layout: {metadata['firstInputLayout']}")
    if metadata.get("firstOutputLayout"):
        print(f"first_output_layout: {metadata['firstOutputLayout']}")
    if metadata.get("firstUnreadableInputLayout"):
        print(f"first_unreadable_input_layout: {metadata['firstUnreadableInputLayout']}")

    result = {}
    result.update(metrics("capture", capture))
    result.update(metrics("processed", processed))
    result.update(compare(capture, processed))
    for key, value in result.items():
        if key.endswith("_frames"):
            print(f"{key}: {int(value)}")
        else:
            print(f"{key}: {value:.4f}")


if __name__ == "__main__":
    main()
