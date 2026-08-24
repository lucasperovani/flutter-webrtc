#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <WebRTC/WebRTC.h>

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

/// Records audio from an [RTCAudioTrack] (local or remote) to a compressed
/// audio file (AAC/M4A) using AVAssetWriter.
@interface FlutterRTCAudioRecorder : NSObject

@property(nonatomic, strong) NSURL* _Nonnull output;
@property(nonatomic, strong) AVAssetWriter* _Nullable assetWriter;
@property(nonatomic, strong) AVAssetWriterInput* _Nullable audioWriter;

/// Initializes a recorder for the given audio track.
/// The track may be a remote track received via the peer connection.
- (instancetype _Nonnull)initWithAudioTrack:(RTCAudioTrack* _Nonnull)audio
                                 outputFile:(NSURL* _Nonnull)out;

/// Prepares the audio sink without starting the file writer.
/// This lets the caller hear the WebRTC audio before recording begins.
- (void)prepare;

/// Starts recording to the given output file.
/// If [recordingStartTime] is greater than 0, the audio timeline is anchored
/// to that wall-clock time (seconds since epoch) so it can be synchronized
/// with another stream (e.g. camera). Pass 0 to keep the legacy behavior.
- (void)startRecordingWithOutputFile:(NSURL* _Nonnull)out
                  recordingStartTime:(NSTimeInterval)recordingStartTime;

/// Convenience that starts recording to the file passed in init.
- (void)startRecordingWithRecordingStartTime:(NSTimeInterval)recordingStartTime;

/// Stops recording, finalizes the file, and releases the audio sink.
/// Calls [result] on the main thread when done.
- (void)stop:(_Nonnull FlutterResult)result;

@end