# VIA Final Project

This repository contains a final-project prototype for assisting visually impaired users with live scene descriptions, plus the evaluation materials used to assess the system on recorded test videos.

## Project Overview

`VIA` is a camera-based assistive app built with Flutter. The current implementation:

- opens the device camera and captures frames in real time
- sends compressed image data to a FastVLM-compatible HTTP service
- sanitizes the model response into a short walking-oriented description
- optionally translates the description into Thai
- reads results aloud with text-to-speech and shows them on screen

The app is focused on mobile usage. Flutter platform folders for desktop and web exist, but the main experience depends on camera access and has been structured like a phone app.

## Repository Structure

```text
.
├── app/
│   └── Application-Assist-the-Visually-Impaired/
│       └── flutter_app/
├── data/
│   ├── video/
│   └── video_labeled/
└── docs/
```

## Flutter App

Path: `app/Application-Assist-the-Visually-Impaired/flutter_app`

### Main capabilities

- live camera preview
- remote vision-language inference through a configurable `VLM_BASE_URL`
- response cleanup for clearer safety-oriented output
- optional Thai translation before playback
- text-to-speech, subtitles, vibration, and speech-rate settings
- periodic inference throttling for more stable output

### Runtime flow

1. The app boots and checks the VLM service health endpoint.
2. It detects an available camera and opens the preview.
3. Frames are compressed to JPEG and sent to the `/infer` endpoint.
4. The returned caption is cleaned up and optionally translated to Thai.
5. The result is displayed and spoken to the user.

### Requirements

- Flutter SDK with a Dart version compatible with `sdk: ^3.9.2`
- a device or emulator with camera support
- internet access to the configured VLM service
- internet access to Google Translate if Thai translation is enabled

### Quick start

```bash
cd app/Application-Assist-the-Visually-Impaired/flutter_app
flutter pub get
flutter run
```

The code currently defaults to this remote VLM endpoint:

```text
https://narathip7-fastvlm-space-test.hf.space
```

You can override it at runtime:

```bash
flutter run --dart-define=VLM_BASE_URL=https://your-server.example.com
```

### Supported `--dart-define` values

- `VLM_BASE_URL`: base URL for the model service
- `VLM_MAX_NEW_TOKENS`: max tokens requested from the service
- `VLM_REQUEST_TIMEOUT_SECONDS`: request timeout for inference calls
- `VLM_PROMPT`: custom prompt override

### Useful commands

```bash
flutter analyze
flutter test
```
- The app code in this repository is network-backed today; it calls a remote VLM service over HTTP rather than running an ONNX model locally inside Flutter.
- Thai translation uses the public Google Translate endpoint from the app code, so translation may fail if the network is unavailable.
- Camera permission is required for the main experience to work.
