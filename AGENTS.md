# Global vocal remover

This app removes vocal from system audio globally on macOS. It applies to any running application.

## Audio capture

We use CoreAudio Tap API for capturing and muting app audio. We process them and re-output them.

## Vocal remover

We use a lightweight nerual network (an onnx file) to do this.
