#ifndef RUNNER_AUDIO_MIXER_H_
#define RUNNER_AUDIO_MIXER_H_

#include <deque>
#include <memory>
#include <mutex>
#include <vector>

// Streaming linear-interpolation resampler for mono float audio.
class LinearResampler {
 public:
  LinearResampler(int input_rate, int output_rate);
  std::vector<float> Process(const std::vector<float>& input);

 private:
  double step_;
  double pos_ = 0.0;  // Position of the next output sample; -1 = previous.
  float prev_ = 0.0f;
  bool passthrough_;
};

// Mixes the system (loopback) and microphone streams into one 16 kHz stream
// so both sides of a meeting are transcribed. The microphone delivers audio
// continuously and acts as the clock; loopback delivers nothing while the
// PC is silent, so its samples are buffered and added when available.
class AudioMixer {
 public:
  static constexpr int kRate = 16000;

  AudioMixer() = default;

  // Sample rates are known only once each capture has started; audio that
  // arrives before its rate is set is dropped.
  void SetSystemRate(int rate);
  void SetMicRate(int rate);

  // Thread-safe. Called from the loopback capture thread.
  void AddSystem(const std::vector<float>& samples);

  // Thread-safe. Called from the mic capture thread; returns the mix.
  std::vector<float> AddMic(const std::vector<float>& samples);

 private:
  std::mutex mutex_;
  std::unique_ptr<LinearResampler> system_resampler_;
  std::unique_ptr<LinearResampler> mic_resampler_;
  std::deque<float> system_;
};

#endif  // RUNNER_AUDIO_MIXER_H_
