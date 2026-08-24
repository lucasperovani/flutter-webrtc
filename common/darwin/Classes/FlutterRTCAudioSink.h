#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>

@interface FlutterRTCAudioSink : NSObject <RTCAudioRenderer>

@property (nonatomic, copy) void (^bufferCallback)(CMSampleBufferRef);
@property (nonatomic, copy) void (^pcmCallback)(AVAudioPCMBuffer *pcmBuffer);
@property (nonatomic) CMAudioFormatDescriptionRef format;

- (instancetype) initWithAudioTrack:(RTCAudioTrack*)audio;

- (void) resetTimestamp;

- (void) close;

@end
