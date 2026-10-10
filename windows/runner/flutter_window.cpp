#include "flutter_window.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Posted to the window by the capture thread when audio is queued; channel
// messages must be sent from the platform thread.
constexpr UINT kAudioMessage = WM_APP + 1;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterAudioChannels();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  StopCapture();
  audio_sink_ = nullptr;
  control_channel_ = nullptr;
  audio_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case kAudioMessage:
      DeliverAudio();
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// Channels shared with the Android implementation:
//  - "transcribe/control": capabilities, start {source: system|mic}, stop
//  - "transcribe/audio": stream of Float32List mono chunks
void FlutterWindow::RegisterAudioChannels() {
  auto messenger = flutter_controller_->engine()->messenger();
  const auto& codec = flutter::StandardMethodCodec::GetInstance();

  audio_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, "transcribe/audio", &codec);
  audio_channel_->SetStreamHandler(
      std::make_unique<
          flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            audio_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            audio_sink_ = nullptr;
            return nullptr;
          }));

  control_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "transcribe/control", &codec);
  control_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "capabilities") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("system"), flutter::EncodableValue(true)},
              {flutter::EncodableValue("mic"), flutter::EncodableValue(true)},
              {flutter::EncodableValue("both"), flutter::EncodableValue(true)},
          }));
        } else if (method == "start") {
          std::string source = "system";
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("source"));
            if (it != args->end()) {
              if (const auto* value = std::get_if<std::string>(&it->second)) {
                source = *value;
              }
            }
          }
          int sample_rate = 0;
          std::string error;
          if (StartCapture(source, &sample_rate, &error)) {
            result->Success(flutter::EncodableValue(sample_rate));
          } else {
            result->Error("capture_failed", error);
          }
        } else if (method == "stop") {
          StopCapture();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::QueueAudio(std::vector<float>&& samples) {
  if (samples.empty()) return;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_queue_.push_back(std::move(samples));
  }
  PostMessage(GetHandle(), kAudioMessage, 0, 0);
}

void FlutterWindow::QueueError(const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_error_ = message;
  }
  PostMessage(GetHandle(), kAudioMessage, 0, 0);
}

// |source| is "system" (loopback), "mic", or "both" (loopback + mic mixed,
// so your own voice is included in meeting transcripts).
bool FlutterWindow::StartCapture(const std::string& source, int* sample_rate,
                                 std::string* error) {
  StopCapture();
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    audio_queue_.clear();
    audio_error_.clear();
  }
  auto on_error = [this](const std::string& message) { QueueError(message); };

  if (source != "both") {
    return audio_capture_.Start(
        source != "mic",
        [this](std::vector<float>&& samples) { QueueAudio(std::move(samples)); },
        on_error, sample_rate, error);
  }

  mixer_ = std::make_unique<AudioMixer>();
  AudioMixer* mixer = mixer_.get();
  int system_rate = 0;
  if (!audio_capture_.Start(
          true,
          [mixer](std::vector<float>&& samples) { mixer->AddSystem(samples); },
          on_error, &system_rate, error)) {
    mixer_ = nullptr;
    return false;
  }
  mixer->SetSystemRate(system_rate);
  int mic_rate = 0;
  if (!mic_capture_.Start(
          false,
          [this, mixer](std::vector<float>&& samples) {
            QueueAudio(mixer->AddMic(samples));
          },
          on_error, &mic_rate, error)) {
    audio_capture_.Stop();
    mixer_ = nullptr;
    return false;
  }
  mixer->SetMicRate(mic_rate);
  *sample_rate = AudioMixer::kRate;
  return true;
}

void FlutterWindow::StopCapture() {
  audio_capture_.Stop();
  mic_capture_.Stop();
  mixer_ = nullptr;
}

void FlutterWindow::DeliverAudio() {
  std::deque<std::vector<float>> chunks;
  std::string error;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    chunks.swap(audio_queue_);
    error.swap(audio_error_);
  }
  if (!audio_sink_) return;
  for (auto& chunk : chunks) {
    audio_sink_->Success(flutter::EncodableValue(std::move(chunk)));
  }
  if (!error.empty()) {
    audio_sink_->Error("capture_failed", error);
  }
}
