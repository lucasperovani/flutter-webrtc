#import <AVFoundation/AVFoundation.h>
#import <os/lock.h>

#import "FlutterRTCAudioSink.h"

@implementation FlutterRTCAudioSink {
    os_unfair_lock _lock;

    BOOL _closed;
    RTCAudioTrack *_audioTrack;

    // Continuous audio timeline.
    //
    // Example at 48 kHz with 480 frames per buffer:
    //
    // 0.000
    // 0.010
    // 0.020
    // 0.030
    //
    // This is NOT wall-clock time. It is the timeline of the audio stream.
    CMTime _currentPTS;
}

- (instancetype)initWithAudioTrack:(RTCAudioTrack *)audio {
    self = [super init];

    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _closed = NO;
        _audioTrack = audio;
        _currentPTS = kCMTimeZero;

        [audio addRenderer:self];

        NSLog(
            @"[FlutterRTCAudioSink] Initialized. "
            @"Audio track renderer added."
        );
    }

    return self;
}

#pragma mark - Timestamp

/**
 * Resets the audio timeline.
 *
 * Call this when a NEW recording starts.
 */
- (void)resetTimestamp {
    os_unfair_lock_lock(&_lock);

    _currentPTS = kCMTimeZero;

    os_unfair_lock_unlock(&_lock);

    NSLog(@"[FlutterRTCAudioSink] Audio PTS reset to zero.");
}

#pragma mark - Close

- (void)close {
    os_unfair_lock_lock(&_lock);

    if (_closed) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    _closed = YES;

    self.bufferCallback = nil;

    os_unfair_lock_unlock(&_lock);

    NSLog(@"[FlutterRTCAudioSink] Closing.");

    // removeRenderer: must be called on the main thread according
    // to WebRTC's renderer requirements.
    if ([NSThread isMainThread]) {
        [self doClose];
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self doClose];
        });
    }
}

- (void)doClose {
    if (_audioTrack != nil) {
        [_audioTrack removeRenderer:self];
        _audioTrack = nil;

        NSLog(
            @"[FlutterRTCAudioSink] Audio track renderer removed."
        );
    }
}

#pragma mark - PCM Renderer

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

    if (format == nil || format.streamDescription == NULL) {
        NSLog(@"[FlutterRTCAudioSink] Invalid audio format.");
        return;
    }

    const AudioStreamBasicDescription *asbd =
        format.streamDescription;

    const CMItemCount frameCount =
        (CMItemCount)pcmBuffer.frameLength;

    if (frameCount <= 0) {
        NSLog(@"[FlutterRTCAudioSink] Invalid frame count: %u",
              (unsigned)pcmBuffer.frameLength);
        return;
    }

    const size_t bytesPerFrame =
        asbd->mBytesPerFrame;

    const size_t totalBytes =
        (size_t)frameCount * bytesPerFrame;

    NSLog(
        @"[FlutterRTCAudioSink] PCM: "
        @"frames=%lld rate=%.2f channels=%u "
        @"interleaved=%d bytesPerFrame=%zu totalBytes=%zu",
        (long long)frameCount,
        asbd->mSampleRate,
        (unsigned)asbd->mChannelsPerFrame,
        (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 0 : 1,
        bytesPerFrame,
        totalBytes
    );

    /*
     * ============================================================
     * 1. Create the CMAudioFormatDescription
     * ============================================================
     */

    CMAudioFormatDescriptionRef formatDesc = NULL;

    OSStatus status = CMAudioFormatDescriptionCreate(
        kCFAllocatorDefault,
        asbd,
        0,
        NULL,
        0,
        NULL,
        NULL,
        &formatDesc
    );

    if (status != noErr || formatDesc == NULL) {
        NSLog(
            @"[FlutterRTCAudioSink] "
            @"CMAudioFormatDescriptionCreate failed: %d",
            (int)status
        );

        return;
    }

    /*
     * ============================================================
     * 2. Retrieve the AudioBufferList
     * ============================================================
     */

    const AudioBufferList *sourceABL =
        pcmBuffer.audioBufferList;

    if (sourceABL == NULL ||
        sourceABL->mNumberBuffers == 0) {

        NSLog(
            @"[FlutterRTCAudioSink] "
            @"Invalid AudioBufferList."
        );

        CFRelease(formatDesc);
        return;
    }

    NSLog(
        @"[FlutterRTCAudioSink] "
        @"Source ABL buffers=%u",
        (unsigned)sourceABL->mNumberBuffers
    );

    /*
     * ============================================================
     * 3. Copy the PCM data into our own memory
     *
     * IMPORTANT:
     * Do not pass the AVAudioPCMBuffer's memory directly to the
     * CMSampleBuffer. We allocate a separate block so the sample
     * buffer owns a stable, independent copy of the audio data.
     * ============================================================
     */
    
    uint8_t *audioData = (uint8_t *)malloc(totalBytes);

    if (audioData == NULL) {
        NSLog(
            @"[FlutterRTCAudioSink] "
            @"Failed to allocate %zu bytes.",
            totalBytes
        );

        CFRelease(formatDesc);
        return;
    }

    size_t copiedBytes = 0;

    /*
     * Interleaved case:
     *
     *   mNumberBuffers = 1
     *
     * Mono interleaved case:
     *
     *   buffer[0]
     *   └── all 480 samples
     */

    if ((asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0) {

        const AudioBuffer *src =
            &sourceABL->mBuffers[0];

        if (src->mData == NULL ||
            src->mDataByteSize < totalBytes) {

            NSLog(
                @"[FlutterRTCAudioSink] "
                @"Invalid interleaved buffer. "
                @"data=%p bytes=%u expected=%zu",
                src->mData,
                (unsigned)src->mDataByteSize,
                totalBytes
            );

            free(audioData);
            CFRelease(formatDesc);
            return;
        }

        memcpy(
            audioData,
            src->mData,
            totalBytes
        );

        copiedBytes = totalBytes;
    }

    /*
     * ============================================================
     * 4. Non-interleaved case
     *
     * Not expected for the current audio path, but handled here
     * for correctness and completeness.
     * ============================================================
     */

    else {

        const UInt32 channelCount =
            asbd->mChannelsPerFrame;

        const size_t bytesPerChannel =
            (size_t)frameCount *
            (asbd->mBitsPerChannel / 8);

        if (sourceABL->mNumberBuffers < channelCount) {

            NSLog(
                @"[FlutterRTCAudioSink] "
                @"Invalid non-interleaved ABL. "
                @"buffers=%u channels=%u",
                (unsigned)sourceABL->mNumberBuffers,
                (unsigned)channelCount
            );

            free(audioData);
            CFRelease(formatDesc);
            return;
        }

        /*
         * If the format is non-interleaved, we must interleave the
         * channels to produce a single interleaved PCM buffer.
         *
         * This is required because we create a single CMBlockBuffer
         * below, which expects one contiguous interleaved data block.
         */

        const UInt32 bytesPerSample =
            asbd->mBitsPerChannel / 8;

        for (CMItemCount frame = 0;
             frame < frameCount;
             frame++) {

            for (UInt32 channel = 0;
                 channel < channelCount;
                 channel++) {

                const AudioBuffer *src =
                    &sourceABL->mBuffers[channel];

                if (src->mData == NULL ||
                    src->mDataByteSize < bytesPerChannel) {

                    NSLog(
                        @"[FlutterRTCAudioSink] "
                        @"Invalid non-interleaved buffer."
                    );

                    free(audioData);
                    CFRelease(formatDesc);
                    return;
                }

                const uint8_t *srcBytes =
                    (const uint8_t *)src->mData;

                const size_t srcOffset =
                    (size_t)frame * bytesPerSample;

                const size_t dstOffset =
                    (
                        (size_t)frame * channelCount +
                        channel
                    ) * bytesPerSample;

                memcpy(
                    audioData + dstOffset,
                    srcBytes + srcOffset,
                    bytesPerSample
                );
            }
        }

        copiedBytes = totalBytes;
    }

    /*
     * ============================================================
     * 5. Create a CMBlockBuffer from the PCM data
     * ============================================================
     */

    CMBlockBufferRef blockBuffer = NULL;

    status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        audioData,
        copiedBytes,
        kCFAllocatorDefault,
        NULL,
        0,
        copiedBytes,
        0,
        &blockBuffer
    );

    if (status != kCMBlockBufferNoErr ||
        blockBuffer == NULL) {

        NSLog(
            @"[FlutterRTCAudioSink] "
            @"CMBlockBufferCreateWithMemoryBlock failed: %d",
            (int)status
        );

        /*
         * The CMBlockBuffer was not created, so we must free the
         * allocated audio data manually to avoid a leak.
         */
        free(audioData);

        CFRelease(formatDesc);
        return;
    }

    /*
     * ============================================================
     * 6. Compute the PTS and duration
     * ============================================================
     */

    CMTime duration = CMTimeMake(
        (int64_t)frameCount,
        (int32_t)asbd->mSampleRate
    );

    os_unfair_lock_lock(&_lock);

    CMTime pts = _currentPTS;

    _currentPTS = CMTimeAdd(
        _currentPTS,
        duration
    );

    os_unfair_lock_unlock(&_lock);

    NSLog(
        @"[FlutterRTCAudioSink] "
        @"Creating CMSampleBuffer: "
        @"PTS=%.6f duration=%.6f frames=%lld",
        CMTimeGetSeconds(pts),
        CMTimeGetSeconds(duration),
        (long long)frameCount
    );

    CMSampleTimingInfo timing;

    timing.decodeTimeStamp = kCMTimeInvalid;
    timing.presentationTimeStamp = pts;
    timing.duration = duration;

    /*
     * ============================================================
     * 7. Create a ready CMSampleBuffer
     *
     * We do NOT use:
     *
     * CMSampleBufferSetDataBufferFromAudioBufferList
     *
     * That API was returning -12731 (kCMSampleBufferError_AllocatedData
     * failure), so we build the sample buffer from our own block buffer
     * instead.
     * ============================================================
     */

    CMSampleBufferRef sampleBuffer = NULL;

    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        blockBuffer,
        formatDesc,
        frameCount,
        1,
        &timing,
        0,
        NULL,
        &sampleBuffer
    );

    if (status != noErr ||
        sampleBuffer == NULL) {

        NSLog(
            @"[FlutterRTCAudioSink] "
            @"CMSampleBufferCreateReady failed: %d",
            (int)status
        );

        CFRelease(blockBuffer);
        CFRelease(formatDesc);
        return;
    }

    /*
     * ============================================================
     * 8. Update the exposed audio format
     * ============================================================
     */

    @autoreleasepool {

        self.format =
            (CMAudioFormatDescriptionRef)
            CFAutorelease(
                CFRetain(formatDesc)
            );

        /*
         * The callback receives a CMSampleBuffer that already owns
         * its own CMBlockBuffer, so no extra retain is needed here.
         */
        callback(sampleBuffer);
    }

    /*
     * ============================================================
     * 9. Release local references
     * ============================================================
     */

    CFRelease(sampleBuffer);
    CFRelease(blockBuffer);
    CFRelease(formatDesc);
}

@end