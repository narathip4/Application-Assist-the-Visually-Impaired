# Assist the Visually Impaired

Flutter application that streams camera frames in realtime, runs the FastVLM-0.5B ONNX vision-language model on-device, and surfaces concise descriptions to assist visually impaired users.

## ✨ Features

- Live camera preview with torch, camera-switch, and audio toggle controls.
- Realtime frame throttling and preprocessing (YUV ➜ RGB ➜ CLIP-normalised tensors).
- ONNX Runtime integration for running the FastVLM-0.5B model locally.
- Graceful UI states for camera permission, warm-up, inference-in-progress, and error recovery.
- Test hook to inject a mock model service for fast widget tests.

## 🚀 Getting started

### Prerequisites

- Flutter 3.19+ (or matching the version configured in this repo).
- Dart SDK bundled with Flutter.
- Platform toolchains for the targets you care about (Android Studio, Xcode, etc.).

### Install dependencies

```powershell
flutter pub get
```

### Add the FastVLM model asset

1. Download the **FastVLM-0.5B** ONNX export (0.5B parameters) from your trusted source.
2. Place the `.onnx` file under `models/FastVLM-0.5B-ONNX/` and rename it to `model.onnx` (or adjust the path in `FastVlmService.modelAssetPath`).
3. The directory structure should look like:

```
models/
	FastVLM-0.5B-ONNX/
		model.onnx
```

> ℹ️ The app copies this asset into the platform-specific application support directory on first run. If the asset is missing, the UI will show an error but remain responsive.

### Run the app

```powershell
flutter run
```

Grant camera access when prompted. The description panel will update approximately once per second with the latest FastVLM output.

### Execute tests & static analysis

```powershell
flutter analyze
flutter test
```

The widget test injects a fake FastVLM service, so it runs without the real ONNX model.

## 🛠️ Troubleshooting

- **Model warm-up fails** – ensure the ONNX file exists at the declared asset path and that the device has enough memory to load the 0.5B parameter model.
- **Performance issues** – adjust `_inferenceInterval` in `CameraScreen` to throttle inference frequency or lower the target image size in `FastVlmService`.
- **Platform build errors** – re-run `flutter clean && flutter pub get` and verify platform toolchains are installed.

## 📌 Roadmap ideas

- Integrate text-to-speech playback of generated captions.
- Support batching or streaming prompts for conversational assistance.
- Add offline dataset for quick-start caption examples when the model is still warming up.
