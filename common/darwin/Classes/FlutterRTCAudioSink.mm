#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>
#import "FlutterRTCAudioSink.h"

@implementation FlutterRTCAudioSink {
    os_unfair_lock _lock;
    BOOL _closed;
    RTCAudioTrack *_audioTrack;
}

- (instancetype) initWithAudioTrack:(RTCAudioTrack* )audio {
    self = [super init];
    _lock = OS_UNFAIR_LOCK_INIT;
    _closed = NO;
    _audioTrack = audio;
    [audio addRenderer:self];
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

    // removeRenderer: must be called on the main thread according to WebRTC docs.
    if ([NSThread isMainThread]) {
        [self doClose];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self doClose];
        });
    }
}

- (void) doClose {
    if (_audioTrack != nil) {
        [_audioTrack removeRenderer:self];
        _audioTrack = nil;
    }
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
    os_unfair_lock_lock(&_lock);
    if (_closed) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    void (^callback)(CMSampleBufferRef) = [self.bufferCallback copy];
    os_unfair_lock_unlock(&_lock);

    if (callback == nil || pcmBuffer == nil) {
        return;
    }

    AVAudioFormat *format = pcmBuffer.format;
    AudioStreamBasicDescription asbd = *format.streamDescription;

    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus fmtStatus = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nil, 0, nil, nil, &formatDesc);
    if (fmtStatus != noErr || formatDesc == NULL) {
        return;
    }

    // Build an AudioBufferList from the planar/interleaved PCM data.
    AudioBufferList *abl = (AudioBufferList *)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer) * (pcmBuffer.format.channelCount - 1));
    abl->mNumberBuffers = pcmBuffer.format.channelCount;
    for (AVAudioChannelCount i = 0; i < pcmBuffer.format.channelCount; i++) {
        abl->mBuffers[i].mNumberChannels = 1;
        abl->mBuffers[i].mData = pcmBuffer.mutableAudioBufferList->mBuffers[i].mData;
        abl->mBuffers[i].mDataByteSize = pcmBuffer.mutableAudioBufferList->mBuffers[i].mDataByteSize;
    }

    CMSampleBufferRef buffer = NULL;
    CMSampleTimingInfo timing;
    timing.decodeTimeStamp = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(0, (int32_t)format.sampleRate);
    timing.duration = CMTimeMake(1, (int32_t)format.sampleRate);
    OSStatus bufStatus = CMSampleBufferCreate(kCFAllocatorDefault, nil, false, nil, nil, formatDesc, pcmBuffer.frameLength, 1, &timing, 0, nil, &buffer);
    if (bufStatus != noErr || buffer == NULL) {
        free(abl);
        CFRelease(formatDesc);
        return;
    }
    OSStatus dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(buffer, kCFAllocatorDefault, kCFAllocatorDefault, 0, abl);
    free(abl);
    if (dataStatus != noErr) {
        CFRelease(buffer);
        CFRelease(formatDesc);
        return;
    }

    @autoreleasepool {
        self.format = (CMAudioFormatDescriptionRef)CFAutorelease(CFRetain(formatDesc));
        callback(buffer);
    }
    CFRelease(buffer);
    CFRelease(formatDesc);
}

@end
