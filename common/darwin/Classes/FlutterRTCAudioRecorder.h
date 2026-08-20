#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <WebRTC/WebRTC.h>

#import <Foundation/Foundation.h>

/// Records PCM audio from an [RTCAudioTrack] (local or remote) to a WAV file.
@interface FlutterRTCAudioRecorder : NSObject

/// Initializes a recorder for the given audio track.
/// The track may be a remote track received via the peer connection.
- (instancetype _Nonnull)initWithAudioTrack:(RTCAudioTrack* _Nonnull)audio
                                 outputFile:(NSURL* _Nonnull)out;

/// Stops recording, finalizes the WAV header, and releases the audio sink.
/// Calls [result] on the main thread when done.
- (void)stop:(_Nonnull FlutterResult)result;

@end