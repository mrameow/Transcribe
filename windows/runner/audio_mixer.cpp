#include "audio_mixer.h"

#include <algorithm>

LinearResampler::LinearResampler(int input_rate, int output_rate)
    : step_(static_cast<double>(input_rate) / output_rate),
      passthrough_(input_rate == output_rate) {}

std::vector<float> LinearResampler::Process(const std::vector<float>& x) {
  if (passthrough_ || x.empty()) return x;
  const double n = static_cast<double>(x.size());
  std::vector<float> out;
  out.reserve(static_cast<size_t>(n / step_) + 2);
  while (pos_ <= n - 1) {
    const double floor_pos = pos_ < 0 ? -1.0 : static_cast<double>(
                                                   static_cast<long long>(pos_));
    const double frac = pos_ - floor_pos;
    const float a =
        floor_pos < 0 ? prev_ : x[static_cast<size_t>(floor_pos)];
    const size_t next = static_cast<size_t>(floor_pos + 1);
    const float b = x[std::min(next, x.size() - 1)];
    out.push_back(a + (b - a) * static_cast<float>(frac));
    pos_ += step_;
  }
  pos_ -= n;
  prev_ = x.back();
  return out;
}

void AudioMixer::SetSystemRate(int rate) {
  std::lock_guard<std::mutex> lock(mutex_);
  system_resampler_ = std::make_unique<LinearResampler>(rate, kRate);
}

void AudioMixer::SetMicRate(int rate) {
  std::lock_guard<std::mutex> lock(mutex_);
  mic_resampler_ = std::make_unique<LinearResampler>(rate, kRate);
}

void AudioMixer::AddSystem(const std::vector<float>& samples) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!system_resampler_) return;
  const auto resampled = system_resampler_->Process(samples);
  system_.insert(system_.end(), resampled.begin(), resampled.end());
  // Never lag behind by more than a second if the clocks drift.
  const size_t max_buffered = kRate;
  if (system_.size() > max_buffered) {
    system_.erase(system_.begin(),
                  system_.begin() +
                      static_cast<std::ptrdiff_t>(system_.size() - max_buffered));
  }
}

std::vector<float> AudioMixer::AddMic(const std::vector<float>& samples) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!mic_resampler_) return {};
  auto mixed = mic_resampler_->Process(samples);
  for (float& sample : mixed) {
    float system = 0.0f;
    if (!system_.empty()) {
      system = system_.front();
      system_.pop_front();
    }
    sample = std::clamp(sample + system, -1.0f, 1.0f);
  }
  return mixed;
}
