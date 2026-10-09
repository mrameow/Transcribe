#include "audio_capture.h"

#include <windows.h>

#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>

#include <cstdint>
#include <cstring>
#include <future>
#include <tuple>

namespace {

constexpr REFERENCE_TIME kBufferDuration = 2000000;  // 200 ms in 100ns units.
constexpr int kTargetRate = 16000;

template <typename T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

std::string HrMessage(const char* what, HRESULT hr) {
  char buf[128];
  snprintf(buf, sizeof(buf), "%s failed (0x%08lX)", what,
           static_cast<unsigned long>(hr));
  return buf;
}

// Describes how to turn one captured frame into a mono float sample.
struct SampleFormat {
  bool is_float = false;
  int bits = 16;
  int channels = 1;
  int block_align = 2;
};

SampleFormat DescribeFormat(const WAVEFORMATEX* f) {
  SampleFormat s;
  s.channels = f->nChannels;
  s.block_align = f->nBlockAlign;
  s.bits = f->wBitsPerSample;
  s.is_float = f->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
  if (f->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    auto ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(f);
    s.is_float = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
  }
  return s;
}

float ReadSample(const BYTE* p, const SampleFormat& f) {
  if (f.is_float) {
    float v;
    std::memcpy(&v, p, sizeof(v));
    return v;
  }
  switch (f.bits) {
    case 16: {
      int16_t v;
      std::memcpy(&v, p, sizeof(v));
      return v / 32768.0f;
    }
    case 24: {
      int32_t v = static_cast<int32_t>((uint32_t{p[0]} << 8) |
                                      (uint32_t{p[1]} << 16) |
                                      (uint32_t{p[2]} << 24));
      return v / 2147483648.0f;
    }
    case 32: {
      int32_t v;
      std::memcpy(&v, p, sizeof(v));
      return v / 2147483648.0f;
    }
    default:
      return 0.0f;
  }
}

}  // namespace

AudioCapture::~AudioCapture() { Stop(); }

bool AudioCapture::Start(bool loopback, DataCallback on_data,
                         ErrorCallback on_error, int* sample_rate,
                         std::string* error) {
  Stop();
  on_data_ = std::move(on_data);
  on_error_ = std::move(on_error);
  running_ = true;

  std::promise<std::tuple<bool, int, std::string>> ready;
  auto result = ready.get_future();
  thread_ = std::thread([this, loopback, &ready]() {
    Run(loopback, [&ready](bool ok, int rate, std::string message) {
      ready.set_value({ok, rate, std::move(message)});
    });
  });

  auto [ok, rate, message] = result.get();
  if (!ok) {
    running_ = false;
    thread_.join();
    *error = message;
    return false;
  }
  *sample_rate = rate;
  return true;
}

void AudioCapture::Stop() {
  running_ = false;
  if (thread_.joinable()) thread_.join();
}

void AudioCapture::Run(bool loopback,
                       std::function<void(bool, int, std::string)> ready) {
  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_initialized = SUCCEEDED(hr);

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* mix_format = nullptr;
  bool reported = false;
  std::string failure;

  auto fail = [&](const std::string& message) { failure = message; };

  do {
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
    if (FAILED(hr)) {
      fail(HrMessage("Creating the audio device enumerator", hr));
      break;
    }
    hr = enumerator->GetDefaultAudioEndpoint(loopback ? eRender : eCapture,
                                             eConsole, &device);
    if (FAILED(hr)) {
      fail(loopback ? "No speaker / headphone output device found"
                    : "No microphone found");
      break;
    }

    const DWORD stream_flags = loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0;

    // First ask Windows to convert to 16 kHz mono float for us, which gives
    // the best resampling quality. Fall back to the device's own format.
    WAVEFORMATEX wanted = {};
    wanted.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    wanted.nChannels = 1;
    wanted.nSamplesPerSec = kTargetRate;
    wanted.wBitsPerSample = 32;
    wanted.nBlockAlign = 4;
    wanted.nAvgBytesPerSec = kTargetRate * 4;

    SampleFormat format;
    int rate = kTargetRate;
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&client));
    if (SUCCEEDED(hr)) {
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              stream_flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                  AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                              kBufferDuration, 0, &wanted, nullptr);
    }
    if (SUCCEEDED(hr)) {
      format = DescribeFormat(&wanted);
    } else {
      SafeRelease(&client);
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(&client));
      if (FAILED(hr)) {
        fail(HrMessage("Opening the audio device", hr));
        break;
      }
      hr = client->GetMixFormat(&mix_format);
      if (FAILED(hr)) {
        fail(HrMessage("Reading the audio format", hr));
        break;
      }
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, stream_flags,
                              kBufferDuration, 0, mix_format, nullptr);
      if (FAILED(hr)) {
        fail(HrMessage("Initializing audio capture", hr));
        break;
      }
      format = DescribeFormat(mix_format);
      rate = static_cast<int>(mix_format->nSamplesPerSec);
    }

    hr = client->GetService(IID_PPV_ARGS(&capture));
    if (FAILED(hr)) {
      fail(HrMessage("Getting the capture service", hr));
      break;
    }
    hr = client->Start();
    if (FAILED(hr)) {
      fail(HrMessage("Starting audio capture", hr));
      break;
    }

    ready(true, rate, "");
    reported = true;

    const int bytes_per_sample = format.bits / 8;
    while (running_) {
      Sleep(20);
      UINT32 packet = 0;
      hr = capture->GetNextPacketSize(&packet);
      std::vector<float> out;
      while (SUCCEEDED(hr) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) break;
        const size_t start = out.size();
        out.resize(start + frames, 0.0f);
        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
          for (UINT32 i = 0; i < frames; i++) {
            const BYTE* frame = data + static_cast<size_t>(i) * format.block_align;
            float sum = 0.0f;
            for (int c = 0; c < format.channels; c++) {
              sum += ReadSample(frame + c * bytes_per_sample, format);
            }
            out[start + i] = sum / format.channels;
          }
        }
        capture->ReleaseBuffer(frames);
        hr = capture->GetNextPacketSize(&packet);
      }
      if (FAILED(hr)) {
        if (on_error_) {
          on_error_(hr == AUDCLNT_E_DEVICE_INVALIDATED
                        ? "The audio device was disconnected or changed"
                        : HrMessage("Audio capture", hr));
        }
        break;
      }
      if (!out.empty() && on_data_) on_data_(std::move(out));
    }
    client->Stop();
  } while (false);

  if (!reported) ready(false, 0, failure);

  if (mix_format) CoTaskMemFree(mix_format);
  SafeRelease(&capture);
  SafeRelease(&client);
  SafeRelease(&device);
  SafeRelease(&enumerator);
  if (com_initialized) CoUninitialize();
  running_ = false;
}
