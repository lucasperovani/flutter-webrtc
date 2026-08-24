#import <WebRTC/WebRTC.h>
#import "FlutterRTCAudioRecorder.h"
#import "FlutterRTCAudioSink.h"

#import <AVFoundation/AVFoundation.h>

// Maximum duration to keep in the ring buffer between prepare and startRecording.
static const NSTimeInterval kMaxRingBufferDuration = 2.0;

@implementation FlutterRTCAudioRecorder {
    BOOL _isInitialized;
    BOOL _stopped;
    BOOL _recording;
    BOOL _prepared;
    RTCAudioTrack *_audioTrack;
    FlutterRTCAudioSink *_audioSink;
    AVAssetWriterInput *_audioWriter;
    NSString *_previousAudioCategory;
    NSString *_previousAudioMode;
    AVAudioSessionCategoryOptions _previousAudioCategoryOptions;

    // Buffers received before startRecording, kept so the very beginning of
    // the audio is not lost. Protected by the same unfair lock as the sink.
    NSMutableArray<id> *_ringBuffer;
    NSTimeInterval _ringBufferDuration;

    NSTimeInterval _recordingStartTime;
    CMTime _startPTS;
}

- (instancetype)initWithAudioTrack:(RTCAudioTrack *)audio outputFile:(NSURL *)out {
    self = [super init];
    if (self) {
        _isInitialized = NO;
        _stopped = NO;
        _recording = NO;
        _prepared = NO;
        _audioTrack = audio;
        self.output = out;
        _ringBuffer = [NSMutableArray array];
        _ringBufferDuration = 0;
        _recordingStartTime = 0;
        _startPTS = kCMTimeZero;
    }
    return self;
}

- (void)prepare {
    if (_prepared || _stopped) {
        return;
    }

    _audioSink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:_audioTrack];

    __weak __typeof(self) weakSelf = self;
    _audioSink.bufferCallback = ^(CMSampleBufferRef buffer) {
        FlutterRTCAudioRecorder *strong = weakSelf;
        if (strong == nil || strong->_stopped) {
            return;
        }
        [strong appendSampleBuffer:buffer];
    };

    [_audioSink resetTimestamp];
    [self applyEchoCancellationAudioSession];

    _prepared = YES;

    NSLog(
        @"FlutterRTCAudioRecorder: prepared. "
        @"Sink active, audio should be audible on the device."
    );
}

- (void)startRecordingWithRecordingStartTime:(NSTimeInterval)recordingStartTime {
    [self startRecordingWithOutputFile:self.output recordingStartTime:recordingStartTime];
}

- (void)startRecordingWithOutputFile:(NSURL *)out
                  recordingStartTime:(NSTimeInterval)recordingStartTime {
    if (_recording || _stopped) {
        return;
    }

    if (!_prepared) {
        [self prepare];
    }

    self.output = out;
    _recordingStartTime = recordingStartTime;

    NSLog(
        @"FlutterRTCAudioRecorder: startRecording called. "
        @"output=%@ recordingStartTime=%.6f",
        out,
        recordingStartTime
    );

    // Atomically drain any buffers that arrived while we were in the prepared
    // state and flip to recording mode. New buffers arriving after this point
    // go directly to appendSampleBuffer:.
    NSArray<id> *pendingBuffers = nil;
    @synchronized (self) {
        pendingBuffers = [_ringBuffer copy];
        [_ringBuffer removeAllObjects];
        _ringBufferDuration = 0;
        _recording = YES;
    }

    for (NSValue *value in pendingBuffers) {
        CMSampleBufferRef buffer = (CMSampleBufferRef)value.pointerValue;
        if (buffer != NULL) {
            [self appendSampleBuffer:buffer];
            CFRelease(buffer);
        }
    }
}

- (void)applyEchoCancellationAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // Save current configuration so we can restore it in stop.
    _previousAudioCategory = session.category;
    _previousAudioMode = session.mode;
    _previousAudioCategoryOptions = session.categoryOptions;

    // Configure PlayAndRecord + VideoChat mode to enable iOS AEC.
    // AEC removes from the microphone the audio that is playing on the speaker,
    // preventing echo when the remote WebRTC audio is also being recorded.
    BOOL success = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                            withOptions:AVAudioSessionCategoryOptionAllowBluetooth |
                                        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                        AVAudioSessionCategoryOptionDefaultToSpeaker
                                  error:&error];
    if (!success) {
        NSLog(@"FlutterRTCAudioRecorder: setCategory failed: %@", error.localizedDescription);
    }

    success = [session setMode:AVAudioSessionModeVideoChat error:&error];
    if (!success) {
        NSLog(@"FlutterRTCAudioRecorder: setMode videoChat failed: %@", error.localizedDescription);
    }
}

- (void)restoreAudioSession {
    if (_previousAudioCategory == nil) {
        return;
    }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    BOOL success = [session setCategory:_previousAudioCategory
                            withOptions:_previousAudioCategoryOptions
                                  error:&error];
    if (!success) {
        NSLog(@"FlutterRTCAudioRecorder: restore setCategory failed: %@", error.localizedDescription);
    }
    success = [session setMode:_previousAudioMode error:&error];
    if (!success) {
        NSLog(@"FlutterRTCAudioRecorder: restore setMode failed: %@", error.localizedDescription);
    }
}

- (void)initializeWriterWithFormat:(CMAudioFormatDescriptionRef)format {
    if (format == NULL) {
        NSLog(@"FlutterRTCAudioRecorder: cannot initialize writer with NULL format");
        return;
    }
    if (_isInitialized) {
        return;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    UInt32 channels = asbd ? asbd->mChannelsPerFrame : 1;
    Float64 sampleRate = asbd ? asbd->mSampleRate : 48000.0;

    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    acl.mChannelLayoutTag = channels > 1 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono;

    NSDictionary *audioSettings = @{
        AVFormatIDKey: [NSNumber numberWithInt:kAudioFormatMPEG4AAC],
        AVNumberOfChannelsKey: @(channels),
        AVSampleRateKey: @(sampleRate),
        AVChannelLayoutKey: [NSData dataWithBytes:&acl length:sizeof(AudioChannelLayout)],
        AVEncoderBitRateKey: @128000,
    };
    _audioWriter = [[AVAssetWriterInput alloc]
                    initWithMediaType:AVMediaTypeAudio
                    outputSettings:audioSettings
                    sourceFormatHint:format];
    _audioWriter.expectsMediaDataInRealTime = YES;

    NSError *error;
    self.assetWriter = [[AVAssetWriter alloc]
                        initWithURL:self.output
                        fileType:AVFileTypeMPEG4
                        error:&error];
    if (error != nil || self.assetWriter == nil) {
        NSLog(@"FlutterRTCAudioRecorder: %@", [error localizedDescription]);
        return;
    }
    self.assetWriter.shouldOptimizeForNetworkUse = YES;
    [self.assetWriter addInput:_audioWriter];

    [self.assetWriter startWriting];

    // If a shared recording start time was provided, shift the session start
    // backwards by the sink PTS of the first buffer so that the first written
    // sample lands exactly at recordingStartTime. Buffers keep their original
    // sink PTS, so the relative timing is preserved.
    CMTime sessionStartTime = kCMTimeZero;
    if (_recordingStartTime > 0 && CMTimeCompare(_startPTS, kCMTimeZero) > 0) {
        CMTime anchor = CMTimeMakeWithSeconds(_recordingStartTime, (int32_t)sampleRate);
        sessionStartTime = CMTimeSubtract(anchor, _startPTS);
        if (CMTimeCompare(sessionStartTime, kCMTimeZero) < 0) {
            sessionStartTime = kCMTimeZero;
        }
    }

    NSLog(
        @"FlutterRTCAudioRecorder: initializing writer "
        @"sampleRate=%.0f channels=%u firstSinkPTS=%.6f recordingStartTime=%.6f sessionStartPTS=%.6f",
        sampleRate,
        (unsigned)channels,
        CMTimeGetSeconds(_startPTS),
        _recordingStartTime,
        CMTimeGetSeconds(sessionStartTime)
    );

    [self.assetWriter startSessionAtSourceTime:sessionStartTime];
    _isInitialized = YES;
}

- (void)appendSampleBuffer:(CMSampleBufferRef)buffer {
    if (_stopped || buffer == NULL) {
        return;
    }

    @synchronized (self) {
        // If we are not yet recording, store the buffer in the ring buffer.
        if (!_recording) {
            [self pushToRingBuffer:buffer];
            return;
        }

        if (!_isInitialized) {
            CMAudioFormatDescriptionRef format =
                (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(buffer);
            if (format == NULL) {
                format = _audioSink.format;
            }
            if (format != NULL) {
                // Store the PTS of the very first buffer that initializes the writer.
                // This is the sink-relative time of the first audio sample.
                _startPTS = CMSampleBufferGetPresentationTimeStamp(buffer);
                [self initializeWriterWithFormat:format];
            }
            if (!_isInitialized) {
                NSLog(@"FlutterRTCAudioRecorder: dropping buffer, writer not initialized");
                return;
            }
        }

        if (_audioWriter.readyForMoreMediaData) {
            if (![_audioWriter appendSampleBuffer:buffer]) {
                NSLog(@"FlutterRTCAudioRecorder: failed to append buffer: %@",
                      self.assetWriter.error);
            }
        }
    }
}

- (void)pushToRingBuffer:(CMSampleBufferRef)buffer {
    if (buffer == NULL) {
        return;
    }

    CMTime duration = CMSampleBufferGetDuration(buffer);
    Float64 durationSeconds = CMTimeGetSeconds(duration);
    if (isnan(durationSeconds) || durationSeconds <= 0) {
        durationSeconds = 0.01; // Fallback for malformed buffers.
    }

    while (_ringBufferDuration + durationSeconds > kMaxRingBufferDuration &&
           _ringBuffer.count > 0) {
        NSValue *oldest = _ringBuffer.firstObject;
        CMSampleBufferRef oldestBuffer = (CMSampleBufferRef)oldest.pointerValue;
        CMTime oldestDuration = CMSampleBufferGetDuration(oldestBuffer);
        Float64 oldestSeconds = CMTimeGetSeconds(oldestDuration);
        if (isnan(oldestSeconds) || oldestSeconds <= 0) {
            oldestSeconds = 0.01;
        }
        _ringBufferDuration -= oldestSeconds;
        [_ringBuffer removeObjectAtIndex:0];
        if (oldestBuffer != NULL) {
            CFRelease(oldestBuffer);
        }
    }

    CFRetain(buffer);
    [_ringBuffer addObject:[NSValue valueWithPointer:buffer]];
    _ringBufferDuration += durationSeconds;
}

- (void)clearRingBuffer {
    for (NSValue *value in _ringBuffer) {
        CMSampleBufferRef buffer = (CMSampleBufferRef)value.pointerValue;
        if (buffer != NULL) {
            CFRelease(buffer);
        }
    }
    [_ringBuffer removeAllObjects];
    _ringBufferDuration = 0;
}

- (void)stop:(FlutterResult _Nonnull)result {
    @synchronized (self) {
        _stopped = YES;
        _recording = NO;
    }

    // Remove the sink first (stops callbacks from the audio thread).
    if (_audioSink != nil) {
        [_audioSink close];
        _audioSink = nil;
    }

    // Discard any buffered audio that was never written.
    [self clearRingBuffer];

    // Restore the previous audio session configuration now that recording is done.
    [self restoreAudioSession];

    // If no audio buffer ever arrived.
    if (!_isInitialized) {
        NSLog(@"FlutterRTCAudioRecorder: No audio buffers received, returning without an audio file.");
        result(nil);
        return;
    }

    if (_audioWriter != nil) {
        [_audioWriter markAsFinished];
    }

    if (self.assetWriter == nil) {
        result(nil);
        return;
    }

    AVAssetWriter *writer = self.assetWriter;
    dispatch_async(dispatch_get_main_queue(), ^{
        [writer finishWritingWithCompletionHandler:^{
            NSError *error = writer.error;
            if (error == nil) {
                result(nil);
            } else {
                result([FlutterError errorWithCode:@"Failed to save audio recording"
                                          message:[error localizedDescription]
                                          details:nil]);
            }
        }];
    });
}

- (void)dealloc {
    [self clearRingBuffer];

    if (_audioSink != nil) {
        // RemoveSink must be called on the main thread and complete before
        // the object is deallocated.
        if ([NSThread isMainThread]) {
            [_audioSink close];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_audioSink close];
            });
        }
        _audioSink = nil;
    }
}

@end