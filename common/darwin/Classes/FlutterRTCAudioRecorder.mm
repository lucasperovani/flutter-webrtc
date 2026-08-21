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
    }
    return self;
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

    // NSLog(@"FlutterRTCAudioRecorder: initializing writer with sampleRate=%f channels=%u", sampleRate, (unsigned int)channels);

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
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];
    _isInitialized = YES;
}

- (void)appendSampleBuffer:(CMSampleBufferRef)buffer {
    if (_stopped) {
        return;
    }
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

- (void)stop:(FlutterResult _Nonnull)result {
    _stopped = YES;

    // Remove the sink first (stops callbacks from the audio thread).
    [_audioSink close];
    _audioSink = nil;

    // If no audio buffer ever arrived, create an empty output file so callers
    // can still attempt muxing (FFmpeg will handle the missing audio).
    if (!_isInitialized) {
        NSLog(@"FlutterRTCAudioRecorder: stop called before any audio buffer; creating empty file");
        [[NSFileManager defaultManager] createFileAtPath:self.output.path
                                                  contents:[NSData data]
                                                attributes:nil];
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