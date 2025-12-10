#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class PalabraClient;

@interface PalabraAudioSink : NSObject <RTCAudioRenderer>

@property (nonatomic, weak) PalabraClient *client;

- (instancetype)initWithClient:(PalabraClient *)client;

@end
