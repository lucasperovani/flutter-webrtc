#import "FlutterRTCAudioRecorder.h"
#import "FlutterRTCAudioSink.h"

#import <CoreMedia/CoreMedia.h>

/// WAV header size in bytes.
static const NSUInteger kWAVHeaderSize = 44;

@implementation FlutterRTCAudioRecorder {
    FlutterRTCAudioSink *_audioSink;
    NSURL *_outputURL;
    NSFileHandle *_fileHandle;
    dispatch_queue_t _ioQueue;
    uint64_t _totalDataBytes;
    int _sampleRate;
    int _channels;
    int _bitsPerSample;
    BOOL _headerWritten;
    BOOL _stopped;
}

- (instancetype)initWithAudioTrack:(RTCAudioTrack *)audio outputFile:(NSURL *)out {
    self = [super init];
    if (self) {
        _outputURL = out;
        _audioSink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:audio];
        _ioQueue = dispatch_queue_create("FlutterRTCAudioRecorder.io", DISPATCH_QUEUE_SERIAL);
        _totalDataBytes = 0;
        _sampleRate = 0;
        _channels = 0;
        _bitsPerSample = 16;
        _headerWritten = NO;
        _stopped = NO;

        __weak __typeof(self) weakSelf = self;
        _audioSink.bufferCallback = ^(CMSampleBufferRef buffer) {
            FlutterRTCAudioRecorder *strong = weakSelf;
            if (strong == nil || strong->_stopped) {
                return;
            }
            [strong processSampleBuffer:buffer];
        };
    }
    return self;
}

- (void)processSampleBuffer:(CMSampleBufferRef)buffer {
    // Extract raw PCM data from the sample buffer.
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(buffer);
    if (blockBuffer == NULL) {
        return;
    }

    size_t dataLength = CMBlockBufferGetDataLength(blockBuffer);
    if (dataLength == 0) {
        return;
    }

    // Copy PCM bytes (we must copy — the buffer is owned by WebRTC and may be
    // reused after this callback returns).
    NSMutableData *pcmData = [NSMutableData dataWithLength:dataLength];
    OSStatus status = CMBlockBufferCopyDataBytes(blockBuffer, 0, dataLength, pcmData.mutableBytes);
    if (status != noErr) {
        return;
    }

    // Capture format info from the format description (first callback).
    // All file I/O is dispatched to _ioQueue to avoid races.
    if (!_headerWritten) {
        CMAudioFormatDescriptionRef formatDesc = (CMAudioFormatDescriptionRef)CMSampleBufferGetFormatDescription(buffer);
        if (formatDesc != NULL) {
            const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
            if (asbd != NULL) {
                _sampleRate = (int)asbd->mSampleRate;
                _channels = (int)asbd->mChannelsPerFrame;
                _bitsPerSample = (int)asbd->mBitsPerChannel;
            }
        }
        if (_sampleRate == 0) {
            _sampleRate = 48000;
        }
        if (_channels == 0) {
            _channels = 1;
        }
        _headerWritten = YES;

        // Write the header on the I/O queue so all file access is serialized.
        int sampleRate = _sampleRate;
        int channels = _channels;
        int bitsPerSample = _bitsPerSample;
        NSURL *outputURL = _outputURL;
        __weak __typeof(self) weakSelf = self;
        dispatch_async(_ioQueue, ^{
            FlutterRTCAudioRecorder *strong = weakSelf;
            if (strong == nil || strong->_stopped) {
                return;
            }
            [strong writeWAVHeader:outputURL
                        sampleRate:sampleRate
                          channels:channels
                      bitsPerSample:bitsPerSample];
        });
    }

    uint64_t byteCount = dataLength;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(_ioQueue, ^{
        FlutterRTCAudioRecorder *strong = weakSelf;
        if (strong == nil || strong->_stopped || strong->_fileHandle == nil) {
            return;
        }
        [strong->_fileHandle writeData:pcmData];
        strong->_totalDataBytes += byteCount;
    });
}

- (void)writeWAVHeader:(NSURL *)outputURL
            sampleRate:(int)sampleRate
              channels:(int)channels
          bitsPerSample:(int)bitsPerSample {
    // Create the file and write a placeholder WAV header.
    // The header will be patched with the final data size in [stop].
    [[NSFileManager defaultManager] createFileAtPath:outputURL.path contents:nil attributes:nil];
    _fileHandle = [NSFileHandle fileHandleForWritingAtPath:outputURL.path];

    if (_fileHandle == nil) {
        NSLog(@"FlutterRTCAudioRecorder: failed to create file at %@", outputURL.path);
        return;
    }

    uint16_t audioFormat = 1;   // PCM
    uint16_t numChannels = (uint16_t)channels;
    uint32_t sr = (uint32_t)sampleRate;
    uint16_t bps = (uint16_t)bitsPerSample;
    uint16_t blockAlign = numChannels * bps / 8;
    uint32_t byteRate = sr * blockAlign;
    uint32_t dataSize = 0;      // placeholder, patched in stop

    NSMutableData *header = [NSMutableData dataWithCapacity:kWAVHeaderSize];

    // RIFF chunk descriptor
    [header appendBytes:"RIFF" length:4];
    uint32_t chunkSize = 36 + dataSize;  // placeholder
    [header appendBytes:&chunkSize length:4];
    [header appendBytes:"WAVE" length:4];

    // fmt sub-chunk
    [header appendBytes:"fmt " length:4];
    uint32_t fmtChunkSize = 16;
    [header appendBytes:&fmtChunkSize length:4];
    [header appendBytes:&audioFormat length:2];
    [header appendBytes:&numChannels length:2];
    [header appendBytes:&sr length:4];
    [header appendBytes:&byteRate length:4];
    [header appendBytes:&blockAlign length:2];
    [header appendBytes:&bps length:2];

    // data sub-chunk
    [header appendBytes:"data" length:4];
    [header appendBytes:&dataSize length:4];

    [_fileHandle writeData:header];
}

- (void)patchWAVHeader {
    if (_fileHandle == nil) {
        return;
    }

    uint32_t dataSize = (uint32_t)_totalDataBytes;
    uint32_t chunkSize = 36 + dataSize;

    // Patch RIFF chunk size (offset 4)
    [_fileHandle seekToFileOffset:4];
    [_fileHandle writeData:[NSData dataWithBytes:&chunkSize length:4]];

    // Patch data sub-chunk size (offset 40)
    [_fileHandle seekToFileOffset:40];
    [_fileHandle writeData:[NSData dataWithBytes:&dataSize length:4]];
}

- (void)stop:(FlutterResult)result {
    _stopped = YES;

    // Remove the sink first (stops callbacks from the audio thread).
    // RemoveSink must be called on the main thread (RTC_DCHECK_RUN_ON(main_thread_)).
    _audioSink.bufferCallback = nil;
    [_audioSink close];
    _audioSink = nil;

    __weak __typeof(self) weakSelf = self;
    dispatch_async(_ioQueue, ^{
        FlutterRTCAudioRecorder *strong = weakSelf;
        if (strong == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                result(nil);
            });
            return;
        }
        [strong patchWAVHeader];
        [strong->_fileHandle closeFile];
        strong->_fileHandle = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            result(nil);
        });
    });
}

- (void)dealloc {
    if (_audioSink != nil) {
        _audioSink.bufferCallback = nil;
        // RemoveSink must be called on the main thread. If dealloc fires on
        // another thread, dispatch close to main synchronously.
        if ([NSThread isMainThread]) {
            [_audioSink close];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_audioSink close];
            });
        }
    }
    if (_fileHandle != nil) {
        [_fileHandle closeFile];
    }
}

@end