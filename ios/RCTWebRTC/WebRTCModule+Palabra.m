#import "WebRTCModule+Palabra.h"
#import "WebRTCModule+RTCPeerConnection.h"
#import "PalabraClient.h"

@implementation WebRTCModule (Palabra)

RCT_EXPORT_METHOD(startPalabraTranslation
                  : (nonnull NSNumber *)peerConnectionId trackId
                  : (NSString *)trackId clientId
                  : (NSString *)clientId clientSecret
                  : (NSString *)clientSecret sourceLang
                  : (NSString *)sourceLang targetLang
                  : (NSString *)targetLang apiUrl
                  : (NSString *)apiUrl resolver
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    
    RTCPeerConnection *peerConnection = self.peerConnections[peerConnectionId];
    if (!peerConnection) {
        reject(@"E_INVALID", @"pc_not_found", nil);
        return;
    }
    
    RTCMediaStreamTrack *track = peerConnection.remoteTracks[trackId];
    if (!track) {
        reject(@"E_INVALID", @"track_not_found", nil);
        return;
    }
    
    if (![track.kind isEqualToString:@"audio"]) {
        reject(@"E_INVALID", @"not_audio_track", nil);
        return;
    }
    
    RTCAudioTrack *audioTrack = (RTCAudioTrack *)track;
    
    if (self.palabraClient) {
        [self.palabraClient stop];
    }
    
    self.palabraClient = [[PalabraClient alloc] initWithClientId:clientId
                                                    clientSecret:clientSecret
                                                          apiUrl:apiUrl
                                                          module:self];
    self.palabraClient.delegate = self;
    
    [self.palabraClient startWithTrack:audioTrack
                            sourceLang:sourceLang
                            targetLang:targetLang];
    
    resolve(nil);
}

RCT_EXPORT_METHOD(stopPalabraTranslation
                  : (RCTPromiseResolveBlock)resolve rejecter
                  : (RCTPromiseRejectBlock)reject) {
    
    if (self.palabraClient) {
        [self.palabraClient stop];
        self.palabraClient = nil;
    }
    
    resolve(nil);
}

#pragma mark - PalabraClientDelegate

- (void)palabraDidReceiveTranscription:(NSDictionary *)transcription {
    [self sendEventWithName:kEventPalabraTranscription body:transcription];
}

- (void)palabraDidChangeConnectionState:(NSString *)state {
    [self sendEventWithName:kEventPalabraConnectionState body:@{@"state": state}];
}

- (void)palabraDidFailWithError:(NSError *)error {
    [self sendEventWithName:kEventPalabraError body:@{
        @"code": @(error.code),
        @"message": error.localizedDescription ?: @"unknown_error"
    }];
}

@end
