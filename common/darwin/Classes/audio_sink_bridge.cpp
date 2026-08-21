#include "media_stream_interface.h"
#include "FlutterRTCAudioSink-Interface.h"

class AudioSinkBridge : public webrtc::AudioTrackSinkInterface {
private:
    void* sink;
    std::atomic<bool> _closed;

public:
    AudioSinkBridge(void* sink1) {
        sink = sink1;
        _closed.store(false);
    }

    void Close() {
        _closed.store(true);
    }

    void OnData(const void* audio_data,
                        int bits_per_sample,
                        int sample_rate,
                        size_t number_of_channels,
                        size_t number_of_frames) override
    {
        if (_closed.load()) {
            return;
        }
        // Defensive null-check in case the audio thread still reaches us after
        // the bridge has been detached but before the delayed deleter runs.
        if (sink == nullptr) {
            return;
        }
        RTCAudioSinkCallback(sink,
                             audio_data,
                             bits_per_sample,
                             sample_rate,
                             number_of_channels,
                             number_of_frames
        );
    };
    int NumPreferredChannels() const override { return 1; }
};
