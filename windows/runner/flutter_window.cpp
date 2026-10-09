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
  audio_capture_.Stop();
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
          }));
        } else if (method == "start") {
          bool loopback = true;
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = args->find(flutter::EncodableValue("source"));
            if (it != args->end()) {
              if (const auto* source = std::get_if<std::string>(&it->second)) {
                loopback = *source != "mic";
              }
            }
          }
          {
            std::lock_guard<std::mutex> lock(audio_mutex_);
            audio_queue_.clear();
            audio_error_.clear();
          }
          HWND hwnd = GetHandle();
          int sample_rate = 0;
          std::string error;
          const bool ok = audio_capture_.Start(
              loopback,
              [this, hwnd](std::vector<float>&& samples) {
                {
                  std::lock_guard<std::mutex> lock(audio_mutex_);
                  audio_queue_.push_back(std::move(samples));
                }
                PostMessage(hwnd, kAudioMessage, 0, 0);
              },
              [this, hwnd](const std::string& message) {
                {
                  std::lock_guard<std::mutex> lock(audio_mutex_);
                  audio_error_ = message;
                }
                PostMessage(hwnd, kAudioMessage, 0, 0);
              },
              &sample_rate, &error);
          if (ok) {
            result->Success(flutter::EncodableValue(sample_rate));
          } else {
            result->Error("capture_failed", error);
          }
        } else if (method == "stop") {
          audio_capture_.Stop();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
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
