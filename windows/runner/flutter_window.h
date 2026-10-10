#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "audio_capture.h"
#include "audio_mixer.h"

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Audio capture bridge, see RegisterAudioChannels().
  void RegisterAudioChannels();
  bool StartCapture(const std::string& source, int* sample_rate,
                    std::string* error);
  void StopCapture();
  // Called on capture threads; hands audio to the platform thread.
  void QueueAudio(std::vector<float>&& samples);
  void QueueError(const std::string& message);
  void DeliverAudio();

  // Default output (loopback) or microphone.
  AudioCapture audio_capture_;
  // Microphone, in "both" mode.
  AudioCapture mic_capture_;
  std::unique_ptr<AudioMixer> mixer_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      control_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      audio_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> audio_sink_;

  // Filled on the capture thread, drained on the platform thread.
  std::mutex audio_mutex_;
  std::deque<std::vector<float>> audio_queue_;
  std::string audio_error_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
