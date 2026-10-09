# Transcribe

Live, **offline** transcription for **Windows** and **Android**. It listens to
Google Meet, Zoom, Teams, YouTube or any other audio playing on your device, or
to the microphone, and turns the speech into text as it is spoken.

- **Runs on your device.** Speech recognition uses
  [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). No audio or text is
  ever sent anywhere.
- **Works offline.** The only internet use is the one-time download of a
  speech model. After that you can turn Wi-Fi off.
- **Live English models** show words as people speak. **Whisper models**
  handle 99 languages, including English, Malay, Chinese, Tamil and
  Indonesian, and add punctuation. They show text one sentence at a time.
- Every session is **saved automatically** as a timestamped `.txt` file. You
  can also copy the whole transcript with one tap.

## Install

Every push builds the apps with GitHub Actions. Open the **Actions** tab of
this repository, pick the latest successful **Build** run, and download from
**Artifacts**:

| Download | For |
|---|---|
| `Transcribe-windows` → `Transcribe-windows-x64.zip` | Windows 10/11 (64-bit). Unzip anywhere and run `transcribe.exe`. |
| `Transcribe-android` → `Transcribe-android-arm64.apk` | Almost every Android phone from the last 7 years |
| `Transcribe-android` → `Transcribe-android-arm32.apk` | Very old or low-end Android phones |

If you push a tag such as `v1.0.0`, the same files are also attached to a
GitHub **Release**.

On Android, allow "Install unknown apps" for your browser or file manager
when it asks. On Windows, SmartScreen may warn about an unrecognised app.
Click **More info → Run anyway**.

## Use it

1. Open the app and tap **Models** (the download icon). Download one model:
   - **English · Live (fast)** for English with instant text. Works well on phones.
   - **Whisper Tiny / Base** for Malay or other languages, or mixed languages.
     Base is more accurate and is a good choice on a PC.
2. Choose the audio source:
   - **System audio** (Windows) / **Other apps** (Android): what the device is playing.
   - **Microphone**: you, or a room.
3. For Whisper, pick the **Language**. A fixed language is more reliable than
   Auto-detect.
4. Press **Start**, then go to your meeting or video. On Android, accept the
   "start recording or casting" prompt. A notification shows while the app
   is listening, and transcription keeps running in the background.
5. Press **Stop**. Use the folder icon to see where transcripts are saved.

### What can be captured

| | Windows | Android |
|---|---|---|
| Google Meet / Zoom / Teams in the browser or desktop app | ✅ System audio | ⚠️ Microphone only (see below) |
| YouTube, video players, browser audio | ✅ System audio | ✅ Other apps (Android 10+) |
| Your own voice | ✅ Microphone | ✅ Microphone |

**Android and calls:** Android does not let any app record the audio of voice
or video calls (Meet, Zoom, WhatsApp, phone calls). This is an OS rule, not a
limit of this app. Some apps also block capture of their audio. For calls on
a phone, choose **Microphone** and put the call on **speaker**.

**Windows:** System audio records what plays on your *default* output device.
Your own voice in a meeting is not included. Use a second device, or run a
session with **Microphone**, if you need both sides.

## Models

| Model | Languages | Download | Notes |
|---|---|---|---|
| English · Live (fast) | English | 122 MB | Streaming; ~45 MB on disk |
| English · Live (accurate) | English | 296 MB | Streaming; needs a faster device |
| Whisper Tiny | 99 languages | 111 MB | Fast; fine on phones |
| Whisper Base | 99 languages | 198 MB | Better accuracy; good on PCs |
| Whisper Small | 99 languages | 610 MB | Best accuracy; needs a fast PC |

Only the int8 weights the app needs are kept after unpacking. You can also
install a model on a device with no internet. Download the `.tar.bz2` from the
[sherpa-onnx asr-models release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models),
unpack it, and copy the folder (plus `silero_vad.onnx` for Whisper) into the
models folder shown at the bottom of the Models screen.

## Build from source

You need [Flutter](https://docs.flutter.dev/get-started/install) 3.47 or newer.

```bash
flutter pub get
flutter test

# Windows (on a Windows PC with Visual Studio "Desktop development with C++")
flutter build windows --release      # → build/windows/x64/runner/Release/

# Android (Android SDK + Java 17)
flutter build apk --release --split-per-abi
```

Release APKs are signed with the debug key, which is fine for installing them
yourself. To publish on the Play Store, set up your own signing key.

To run the recognition tests against real models, put
`sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2`,
`sherpa-onnx-whisper-tiny.tar.bz2`, `silero_vad.onnx` and a 16 kHz
`test.wav` (e.g. `test_wavs/0.wav` from either archive) in one folder, then:

```bash
TRANSCRIBE_TEST_ARCHIVES=/path/to/folder flutter test   # on Linux, also set LD_LIBRARY_PATH to sherpa_onnx_linux's linux/x64
```

## How it works

```
Windows: WASAPI loopback / mic (windows/runner/audio_capture.cpp)  ┐
Android: AudioPlaybackCapture / mic (CaptureService.kt)            ┘─► "transcribe/audio" channel
        ─► background isolate: resample to 16 kHz ─► sherpa-onnx
             • streaming zipformer + endpointing   (lib/src/engine.dart)
             • Silero VAD → Whisper per sentence
        ─► UI (lib/ui/home_page.dart) + auto-saved .txt
```

| Path | What |
|---|---|
| `lib/src/engine.dart` | Recognition engines and the background isolate |
| `lib/src/model_catalog.dart` | Model list and model-file detection |
| `lib/src/model_manager.dart` | Model download and unpacking |
| `lib/src/audio_capture.dart` | Dart side of the native audio channel |
| `windows/runner/audio_capture.cpp` | WASAPI system-audio / mic capture |
| `android/app/src/main/kotlin/.../CaptureService.kt` | Android foreground capture service |
