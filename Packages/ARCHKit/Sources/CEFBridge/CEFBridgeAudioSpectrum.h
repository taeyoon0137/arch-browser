// A passive page-audio observer. Samples stay in this process and only 24 levels reach the UI.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <mutex>
#include "include/cef_audio_handler.h"

namespace cef_bridge {

class AudioSpectrumObserver final : public CefAudioHandler {
public:
    explicit AudioSpectrumObserver(void (^receive)(NSData *)) : receive_([receive copy]) {}

    bool GetAudioParameters(CefRefPtr<CefBrowser>, CefAudioParameters &parameters) override {
        parameters.channel_layout = CEF_CHANNEL_LAYOUT_STEREO;
        parameters.sample_rate = 48000;
        parameters.frames_per_buffer = 2400;
        return true;
    }

    void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters &parameters, int channels) override {
        std::lock_guard<std::mutex> lock(mutex_);
        channels_ = channels;
        sampleRate_ = parameters.sample_rate;
        samples_.fill(0);
        previous_.fill(0);
        sent_.fill(0);
        nextSample_ = filled_ = elapsed_ = 0;
    }

    void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float **data, int frames, int64_t) override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_ || !data || channels_ <= 0 || sampleRate_ <= 0) { return; }
        const int interval = std::max(1, sampleRate_ / 15);
        for (int frame = 0; frame < frames; ++frame) {
            double sum = 0;
            for (int channel = 0; channel < channels_; ++channel) {
                const float value = data[channel] ? data[channel][frame] : 0;
                if (std::isfinite(value)) { sum += value; }
            }
            samples_[nextSample_] = static_cast<float>(sum / channels_);
            nextSample_ = (nextSample_ + 1) % sampleCount;
            filled_ = std::min(filled_ + 1, sampleCount);
            if (++elapsed_ >= interval) {
                elapsed_ -= interval;
                if (filled_ == sampleCount) { analyze(); }
            }
        }
    }

    void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override { clear(); }
    void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString &) override { clear(); }

    /// Called before stopping the engine observer, so callbacks already in flight cannot escape.
    void Stop() {
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = false;
    }

private:
    static constexpr int sampleCount = 1024;
    static constexpr int bandCount = 24;
    static constexpr double pi = 3.14159265358979323846;
    std::mutex mutex_;
    bool active_ = true;
    int channels_ = 0;
    int sampleRate_ = 0;
    int nextSample_ = 0;
    int filled_ = 0;
    int elapsed_ = 0;
    bool queued_ = false;
    bool pendingEmpty_ = false;
    std::array<float, sampleCount> samples_{};
    std::array<double, bandCount> previous_{};
    std::array<uint8_t, bandCount> sent_{};
    std::array<uint8_t, bandCount> pending_{};
    void (^receive_)(NSData *);

    void analyze() {
        std::array<std::complex<double>, sampleCount> bins;
        for (int index = 0; index < sampleCount; ++index) {
            const double window = 0.5 - 0.5 * std::cos(2 * pi * index / (sampleCount - 1));
            bins[index] = samples_[(nextSample_ + index) % sampleCount] * window;
        }
        // Iterative radix-two FFT; its fixed buffers never retain audio beyond the latest window.
        for (int index = 1, reverse = 0; index < sampleCount; ++index) {
            int bit = sampleCount / 2;
            while (reverse & bit) { reverse ^= bit; bit >>= 1; }
            reverse ^= bit;
            if (index < reverse) { std::swap(bins[index], bins[reverse]); }
        }
        for (int span = 2; span <= sampleCount; span *= 2) {
            const std::complex<double> rotation = std::polar(1.0, -2 * pi / span);
            for (int start = 0; start < sampleCount; start += span) {
                std::complex<double> factor = 1;
                for (int index = 0; index < span / 2; ++index) {
                    const auto even = bins[start + index];
                    const auto odd = factor * bins[start + index + span / 2];
                    bins[start + index] = even + odd;
                    bins[start + index + span / 2] = even - odd;
                    factor *= rotation;
                }
            }
        }
        std::array<uint8_t, bandCount> measure;
        bool changed = false;
        const double upperFrequency = std::min(16000.0, sampleRate_ / 2.0);
        for (int band = 0; band < bandCount; ++band) {
            const double low = 60 * std::pow(upperFrequency / 60, double(band) / bandCount);
            const double high = 60 * std::pow(upperFrequency / 60, double(band + 1) / bandCount);
            const int first = std::clamp(int(std::floor(low * sampleCount / sampleRate_)), 1, sampleCount / 2 - 1);
            const int last = std::clamp(int(std::floor(high * sampleCount / sampleRate_)), first + 1, sampleCount / 2);
            double amplitude = 0;
            for (int index = first; index < last; ++index) { amplitude = std::max(amplitude, std::abs(bins[index])); }
            const double decibels = 20 * std::log10(std::max(1e-12, amplitude / (sampleCount / 4.0)));
            const double level = std::clamp((decibels + 72) / 60, 0.0, 1.0);
            previous_[band] = std::max(level, previous_[band] * 0.66);
            measure[band] = static_cast<uint8_t>(std::lround(previous_[band] * 255));
            changed |= std::abs(int(measure[band]) - int(sent_[band])) >= 3 || (measure[band] == 0 && sent_[band] != 0);
        }
        if (!changed) { return; }
        sent_ = pending_ = measure;
        pendingEmpty_ = false;
        enqueue();
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!active_) { return; }
        pendingEmpty_ = true;
        previous_.fill(0);
        sent_.fill(0);
        enqueue();
    }

    /// The audio thread replaces one pending measure instead of queuing one block per packet.
    void enqueue() {
        if (queued_) { return; }
        queued_ = true;
        CefRefPtr<AudioSpectrumObserver> observer(this);
        dispatch_async(dispatch_get_main_queue(), ^{ observer->deliver(); });
    }

    void deliver() {
        NSData *measure;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queued_ = false;
            if (!active_) { return; }
            measure = pendingEmpty_ ? NSData.data : [NSData dataWithBytes:pending_.data() length:pending_.size()];
        }
        receive_(measure);
    }

    IMPLEMENT_REFCOUNTING(AudioSpectrumObserver);
};

}  // namespace cef_bridge
