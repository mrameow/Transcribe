#ifndef RUNNER_AUDIO_CAPTURE_H_
#define RUNNER_AUDIO_CAPTURE_H_

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

// Captures mono float audio with WASAPI, either from the default microphone
// or (loopback) from whatever is playing on the default output device, e.g.
// a Google Meet / Zoom / Teams call or a video in the browser.
class AudioCapture {
 public:
  // Called on the capture thread with mono samples in [-1, 1].
  using DataCallback = std::function<void(std::vector<float>&&)>;
  // Called on the capture thread if capture fails after it started.
  using ErrorCallback = std::function<void(const std::string&)>;

  AudioCapture() = default;
  ~AudioCapture();
  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  // Starts capturing. On success returns true and sets |sample_rate|.
  bool Start(bool loopback, DataCallback on_data, ErrorCallback on_error,
             int* sample_rate, std::string* error);
  void Stop();
  bool running() const { return running_; }

 private:
  void Run(bool loopback, std::function<void(bool, int, std::string)> ready);

  std::thread thread_;
  std::atomic<bool> running_{false};
  DataCallback on_data_;
  ErrorCallback on_error_;
};

#endif  // RUNNER_AUDIO_CAPTURE_H_
