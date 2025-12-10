#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class WebRTCModule;

@protocol PalabraClientDelegate <NSObject>
@optional
- (void)palabraDidReceiveTranscription:(NSDictionary *)transcription;
- (void)palabraDidChangeConnectionState:(NSString *)state;
- (void)palabraDidFailWithError:(NSError *)error;
@end

@interface PalabraClient : NSObject

@property (nonatomic, weak) id<PalabraClientDelegate> delegate;
@property (nonatomic, weak) WebRTCModule *module;
@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) BOOL isTranslating;

- (instancetype)initWithClientId:(NSString *)clientId
                    clientSecret:(NSString *)clientSecret
                          apiUrl:(NSString *)apiUrl
                          module:(WebRTCModule *)module;

- (void)startWithTrack:(RTCAudioTrack *)remoteAudioTrack
            sourceLang:(NSString *)sourceLang
            targetLang:(NSString *)targetLang;

- (void)stop;

- (void)setTranslatedVolume:(double)volume;

- (void)sendAudioToPalabra:(AVAudioPCMBuffer *)buffer;

@end
