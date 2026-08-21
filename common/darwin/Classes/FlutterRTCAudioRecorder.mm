#import <WebRTC/WebRTC.h>
#import "FlutterRTCAudioRecorder.h"
#import "FlutterRTCAudioSink.h"

#import <AVFoundation/AVFoundation.h>

@implementation FlutterRTCAudioRecorder {
    BOOL _isInitialized;
    BOOL _stopped;
    FlutterRTCAudioSink *_audioSink;
    AVAssetWriterInput *_audioWriter;
}

- (instancetype)initWithAudioTrack:(RTCAudioTrack *)audio outputFile:(NSURL *)out {
    self = [super init];
    if (self) {
        _isInitialized = NO;
        _stopped = NO;
        self.output = out;
        _audioSink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:audio];

        __weak __typeof(self) weakSelf = self;
        _audioSink.bufferCallback = ^(CMSampleBufferRef buffer) {
            FlutterRTCAudioRecorder *strong = weakSelf;
            if (strong == nil || strong->_stopped) {
                return;
            }
            [strong appendSampleBuffer:buffer];
        };

        // Eagerly initialize the asset writer so that stop() always has a
        // valid writer to finalize, even if no audio buffer arrives before
        // the user stops the recording.
        [self initializeWriterWithFormat:[self defaultFormatDescription]];
    }
    return self;
}

- (CMAudioFormatDescriptionRef)defaultFormatDescription {
    AudioStreamBasicDescription audioDescription;
    bzero(&audioDescription, sizeof(audioDescription));
    audioDescription.mFormatID = kAudioFormatLinearPCM;
    audioDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    audioDescription.mSampleRate = 48000.0;
    audioDescription.mChannelsPerFrame = 2;
    audioDescription.mBitsPerChannel = 16;
    audioDescription.mBytesPerFrame = audioDescription.mBitsPerChannel / 8 * audioDescription.mChannelsPerFrame;
    audioDescription.mBytesPerPacket = audioDescription.mBytesPerFrame;
    audioDescription.mFramesPerPacket = 1;
    audioDescription.mReserved = 0;

    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus fmtStatus = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &audioDescription, 0, nil, 0, nil, nil, &formatDesc);
    if (fmtStatus != noErr || formatDesc == NULL) {
        return NULL;
    }
    return (CMAudioFormatDescriptionRef)CFAutorelease(formatDesc);
}

- (void)initializeWriterWithFormat:(CMAudioFormatDescriptionRef)format {
    if (format == NULL) {
        NSLog(@"FlutterRTCAudioRecorder: cannot initialize writer with NULL format");
        return;
    }
    if (_isInitialized) {
        return;
    }

    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    NSDictionary *audioSettings = @{
        AVFormatIDKey: [NSNumber numberWithInt:kAudioFormatMPEG4AAC],
        AVNumberOfChannelsKey: @2,
        AVSampleRateKey: @48000.0,
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
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    _isInitialized = YES;
}

- (void)appendSampleBuffer:(CMSampleBufferRef)buffer {
    if (!_isInitialized) {
        CMAudioFormatDescriptionRef format =
            (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(buffer);
        if (format == NULL) {
            format = _audioSink.format;
        }
        if (format != NULL) {
            [self initializeWriterWithFormat:format];
        }
        if (!_isInitialized) {
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

- (void)stop:(FlutterResult _Nonnull)result {
    _stopped = YES;

    // Remove the sink first (stops callbacks from the audio thread).
    [_audioSink close];
    _audioSink = nil;

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