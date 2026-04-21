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

## Android release builds

The Android app is configured to use:

- Application ID: `app.via.visualassistant`
- Release signing from `android/key.properties`

### 1. Create an upload keystore

Run this from the project root:

```bash
keytool -genkeypair -v -keystore android/app/upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

### 2. Add local signing config

`android/key.properties` is already prepared locally for this workspace.
Open it and replace the placeholder values with your real passwords and alias:

```properties
storePassword=your-keystore-password
keyPassword=your-key-password
keyAlias=upload
storeFile=app/upload-keystore.jks
```

### 3. Build a signed release

```bash
flutter build apk --release --dart-define=VLM_BASE_URL=https://your-api
flutter build appbundle --release --dart-define=VLM_BASE_URL=https://your-api
```

Or use the helper script:

```bash
bash scripts/build_android_release.sh apk
bash scripts/build_android_release.sh aab
bash scripts/build_android_release.sh apk-split
```

You can also pass the production backend URL directly:

```bash
bash scripts/build_android_release.sh aab https://your-api
VLM_BASE_URL=https://your-api bash scripts/build_android_release.sh apk
```

Outputs:

- APK: `build/app/outputs/flutter-apk/app-release.apk`
- AAB: `build/app/outputs/bundle/release/app-release.aab`

## 🛠️ Troubleshooting

- **Model warm-up fails** – ensure the ONNX file exists at the declared asset path and that the device has enough memory to load the 0.5B parameter model.
- **Performance issues** – adjust `_inferenceInterval` in `CameraScreen` to throttle inference frequency or lower the target image size in `FastVlmService`.
- **Platform build errors** – re-run `flutter clean && flutter pub get` and verify platform toolchains are installed.

## 📌 Roadmap ideas

- Integrate text-to-speech playback of generated captions.
- Support batching or streaming prompts for conversational assistance.
- Add offline dataset for quick-start caption examples when the model is still warming up.
