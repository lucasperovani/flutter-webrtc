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

/// Stops recording, finalizes the file, and releases the audio sink.
/// Calls [result] on the main thread when done.
- (void)stop:(_Nonnull FlutterResult)result;

@end