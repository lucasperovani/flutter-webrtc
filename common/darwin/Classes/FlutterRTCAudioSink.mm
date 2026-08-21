#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import "FlutterRTCAudioSink.h"
#import "RTCAudioSource+Private.h"
#include <atomic>
#include "media_stream_interface.h"
#include "audio_sink_bridge.cpp"

/// Holds a C++ AudioSinkBridge and the matching CFBridgingRetain on the
/// Objective-C sink. Deletes the bridge and releases the sink after a short
/// delay, giving the WebRTC audio thread time to finish any in-flight OnData
/// call that may still reference the bridge.
class AudioSinkBridgeDelayedDeleter {
public:
    AudioSinkBridgeDelayedDeleter(AudioSinkBridge* bridge, CFTypeRef sinkRef)
        : _bridge(bridge), _sinkRef(sinkRef) {}
    ~AudioSinkBridgeDelayedDeleter() {
        delete _bridge;
        CFRelease(_sinkRef);
    }
private:
    AudioSinkBridge* _bridge;
    CFTypeRef _sinkRef;
};

@implementation FlutterRTCAudioSink {
    AudioSinkBridge *_bridge;
    webrtc::AudioSourceInterface* _audioSource;
    os_unfair_lock _lock;
    BOOL _closed;
}

- (instancetype) initWithAudioTrack:(RTCAudioTrack* )audio {
    self = [super init];
    _lock = OS_UNFAIR_LOCK_INIT;
    _closed = NO;
    rtc::scoped_refptr<webrtc::AudioSourceInterface> audioSourcePtr = audio.source.nativeAudioSource;
    _audioSource = audioSourcePtr.get();
    _bridge = new AudioSinkBridge((void*)CFBridgingRetain(self));
    _audioSource->AddSink(_bridge);
    return self;
}

- (void) close {
    os_unfair_lock_lock(&_lock);
    if (_closed) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    _closed = YES;
    self.bufferCallback = nil;
    os_unfair_lock_unlock(&_lock);

    // Tell the C++ bridge to stop invoking the Objective-C callback immediately,
    // even if RemoveSink has not finished yet.
    if (_bridge != nil) {
        _bridge->Close();
    }

    // RemoveSink must complete before the bridge object or self can be destroyed,
    // because the audio thread may still be inside OnData -> RTCAudioSinkCallback.
    // RemoveSink on WebRTC is synchronous on the caller side, but run it on the
    // main thread to match WebRTC thread expectations and avoid deadlocks.
    if ([NSThread isMainThread]) {
        [self doClose];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self doClose];
        });
    }
}

- (void) doClose {
    if (_audioSource != nil) {
        _audioSource->RemoveSink(_bridge);
        _audioSource = nil;
    }
    if (_bridge != nil) {
        // Keep the Objective-C sink alive and defer deletion of the C++ bridge.
        // The WebRTC audio thread may still be inside OnData even after RemoveSink
        // returns; deleting the bridge immediately causes AURemoteIO EXC_BAD_ACCESS.
        // The delayed deleter is destroyed (and frees the bridge + releases self) on
        // a background queue after a short grace period.
        CFTypeRef sinkRef = (__bridge_retained CFTypeRef)(self);
        AudioSinkBridge* bridge = _bridge;
        _bridge = nil;
        // Use a longer grace period. The WebRTC audio thread may have already
        // read our sink pointer from the internal sink list before RemoveSink
        // acquired its mutex; deleting the bridge too early causes it to call
        // a dangling vtable. 1.5s is conservative for a 10ms audio callback.
        NSLog(@"FlutterRTCAudioSink: deferring bridge deletion for 1.5s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSLog(@"FlutterRTCAudioSink: deleting deferred bridge");
            AudioSinkBridgeDelayedDeleter deleter(bridge, sinkRef);
        });
    }
}

void RTCAudioSinkCallback (void *object, const void *audio_data, int bits_per_sample, int sample_rate, size_t number_of_channels, size_t number_of_frames)
{
    FlutterRTCAudioSink* sink = (__bridge FlutterRTCAudioSink*)(object);

    os_unfair_lock_lock(&sink->_lock);
    if (sink->_closed) {
        os_unfair_lock_unlock(&sink->_lock);
        return;
    }
    void (^callback)(CMSampleBufferRef) = [sink.bufferCallback copy];
    os_unfair_lock_unlock(&sink->_lock);

    if (callback == nil) {
        return;
    }

    AudioBufferList audioBufferList;
    AudioBuffer audioBuffer;
    audioBuffer.mData = (void*) audio_data;
    audioBuffer.mDataByteSize = bits_per_sample / 8 * number_of_channels * number_of_frames;
    audioBuffer.mNumberChannels = number_of_channels;
    audioBufferList.mNumberBuffers = 1;
    audioBufferList.mBuffers[0] = audioBuffer;
    AudioStreamBasicDescription audioDescription;
    audioDescription.mBytesPerFrame = bits_per_sample / 8 * number_of_channels;
    audioDescription.mBitsPerChannel = bits_per_sample;
    audioDescription.mBytesPerPacket = bits_per_sample / 8 * number_of_channels;
    audioDescription.mChannelsPerFrame = number_of_channels;
    audioDescription.mFormatID = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    audioDescription.mFramesPerPacket = 1;
    audioDescription.mReserved = 0;
    audioDescription.mSampleRate = sample_rate;
    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus fmtStatus = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &audioDescription, 0, nil, 0, nil, nil, &formatDesc);
    if (fmtStatus != noErr || formatDesc == NULL) {
        return;
    }
    CMSampleBufferRef buffer = NULL;
    CMSampleTimingInfo timing;
    timing.decodeTimeStamp = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(0, sample_rate);
    timing.duration = CMTimeMake(1, sample_rate);
    OSStatus bufStatus = CMSampleBufferCreate(kCFAllocatorDefault, nil, false, nil, nil, formatDesc, number_of_frames * number_of_channels, 1, &timing, 0, nil, &buffer);
    if (bufStatus != noErr || buffer == NULL) {
        CFRelease(formatDesc);
        return;
    }
    OSStatus dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(buffer, kCFAllocatorDefault, kCFAllocatorDefault, 0, &audioBufferList);
    if (dataStatus != noErr) {
        CFRelease(buffer);
        CFRelease(formatDesc);
        return;
    }
    @autoreleasepool {
        // Retain formatDesc for the sink property (previous value is released by ARC).
        sink.format = (CMAudioFormatDescriptionRef)CFAutorelease(CFRetain(formatDesc));
        callback(buffer);
    }
    CFRelease(buffer);
    CFRelease(formatDesc);
}

@end
