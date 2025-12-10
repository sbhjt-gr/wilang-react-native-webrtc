#import "PalabraClient.h"
#import "WebRTCModule.h"
#import <AVFoundation/AVFoundation.h>

static const int kSampleRate = 16000;
static const int kChannels = 1;
static const int kChunkMs = 320;
static const int kChunkSamples = kSampleRate * kChunkMs / 1000;
static const int kChunkBytes = kChunkSamples * 2;

@interface PalabraClient () <NSURLSessionWebSocketDelegate, RTCAudioRenderer>

@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, strong) NSString *clientSecret;
@property (nonatomic, strong) NSString *apiUrl;
@property (nonatomic, strong) NSString *sourceLang;
@property (nonatomic, strong) NSString *targetLang;

@property (nonatomic, strong) RTCAudioTrack *remoteTrack;

@property (nonatomic, strong) NSString *sessionId;
@property (nonatomic, strong) NSString *wsUrl;
@property (nonatomic, strong) NSString *publisherToken;

@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocket;

@property (nonatomic, strong) AVAudioEngine *audioEngine;
@property (nonatomic, strong) AVAudioPlayerNode *playerNode;
@property (nonatomic, strong) AVAudioFormat *audioFormat;

@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) BOOL translating;
@property (nonatomic, assign) double originalVolume;

@property (nonatomic, strong) NSMutableData *audioBuffer;
@property (nonatomic, strong) NSLock *bufferLock;

@end

@implementation PalabraClient

- (instancetype)initWithClientId:(NSString *)clientId
                    clientSecret:(NSString *)clientSecret
                          apiUrl:(NSString *)apiUrl
                          module:(WebRTCModule *)module {
    self = [super init];
    if (self) {
        _clientId = clientId;
        _clientSecret = clientSecret;
        _apiUrl = apiUrl;
        _module = module;
        _connected = NO;
        _translating = NO;
        _originalVolume = 1.0;
        _audioBuffer = [NSMutableData new];
        _bufferLock = [NSLock new];
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        
        [self setupAudioEngine];
    }
    return self;
}

- (BOOL)isConnected {
    return _connected;
}

- (BOOL)isTranslating {
    return _translating;
}

- (void)setupAudioEngine {
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.playerNode = [[AVAudioPlayerNode alloc] init];
    [self.audioEngine attachNode:self.playerNode];
    
    self.audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                        sampleRate:kSampleRate
                                                          channels:kChannels
                                                       interleaved:YES];
    
    [self.audioEngine connect:self.playerNode
                           to:self.audioEngine.mainMixerNode
                       format:self.audioFormat];
}

- (void)startWithTrack:(RTCAudioTrack *)remoteAudioTrack
            sourceLang:(NSString *)sourceLang
            targetLang:(NSString *)targetLang {
    
    if (self.translating) {
        return;
    }
    
    self.remoteTrack = remoteAudioTrack;
    self.sourceLang = sourceLang;
    self.targetLang = targetLang;
    
    self.originalVolume = remoteAudioTrack.source.volume;
    remoteAudioTrack.source.volume = 0;
    
    [self notifyConnectionState:@"connecting"];
    
    __weak typeof(self) weakSelf = self;
    [self createSessionWithCompletion:^(NSDictionary *session, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (error) {
            [strongSelf notifyError:error];
            strongSelf.remoteTrack.source.volume = strongSelf.originalVolume;
            return;
        }
        
        NSDictionary *data = session[@"data"];
        strongSelf.sessionId = data[@"id"];
        strongSelf.wsUrl = data[@"ws_url"];
        strongSelf.publisherToken = data[@"publisher"];
        
        NSLog(@"palabra_ws_url: %@", strongSelf.wsUrl);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf connectWebSocket];
        });
    }];
}

- (void)createSessionWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *urlStr = [NSString stringWithFormat:@"%@/session-storage/session", self.apiUrl];
    NSURL *url = [NSURL URLWithString:urlStr];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:self.clientId forHTTPHeaderField:@"ClientId"];
    [request setValue:self.clientSecret forHTTPHeaderField:@"ClientSecret"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *body = @{
        @"data": @{
            @"subscriber_count": @0,
            @"publisher_can_subscribe": @YES
        }
    };
    
    NSError *jsonError;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    
    if (jsonError) {
        completion(nil, jsonError);
        return;
    }
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error);
                });
                return;
            }
            
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                NSError *httpError = [NSError errorWithDomain:@"PalabraClient"
                                                        code:httpResponse.statusCode
                                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"session_http_error_%ld", (long)httpResponse.statusCode]}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, httpError);
                });
                return;
            }
            
            NSError *parseError;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(json, parseError);
            });
        }];
    
    [task resume];
}

- (void)connectWebSocket {
    NSString *endpoint = [NSString stringWithFormat:@"%@?token=%@", self.wsUrl, self.publisherToken];
    NSLog(@"palabra_connecting_ws: %@", endpoint);
    
    NSURL *url = [NSURL URLWithString:endpoint];
    self.webSocket = [self.urlSession webSocketTaskWithURL:url];
    [self.webSocket resume];
    
    [self receiveMessage];
    
    self.connected = YES;
    self.translating = YES;
    
    [self.remoteTrack addRenderer:self];
    
    NSError *audioError;
    [self.audioEngine startAndReturnError:&audioError];
    if (!audioError) {
        [self.playerNode play];
    }
    
    [self notifyConnectionState:@"connected"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self sendSetTask];
    });
}

- (void)receiveMessage {
    if (!self.webSocket) return;
    
    __weak typeof(self) weakSelf = self;
    [self.webSocket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (error) {
            NSLog(@"palabra_ws_error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf stop];
                [strongSelf notifyError:error];
            });
            return;
        }
        
        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            [strongSelf handleMessage:message.string];
        }
        
        [strongSelf receiveMessage];
    }];
}

- (void)sendSetTask {
    if (!self.webSocket || !self.connected) return;
    
    NSDictionary *msg = @{
        @"message_type": @"set_task",
        @"data": @{
            @"input_stream": @{
                @"content_type": @"audio",
                @"source": @{
                    @"type": @"ws",
                    @"format": @"pcm_s16le",
                    @"sample_rate": @(kSampleRate),
                    @"channels": @(kChannels)
                }
            },
            @"output_stream": @{
                @"content_type": @"audio",
                @"target": @{
                    @"type": @"ws",
                    @"format": @"pcm_s16le"
                }
            },
            @"pipeline": @{
                @"transcription": @{
                    @"source_language": self.sourceLang
                },
                @"translations": @[@{
                    @"target_language": self.targetLang,
                    @"speech_generation": @{
                        @"voice_cloning": @NO
                    }
                }],
                @"allowed_message_types": @[
                    @"partial_transcription",
                    @"validated_transcription",
                    @"translated_transcription"
                ]
            }
        }
    };
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
    if (error) {
        NSLog(@"palabra_set_task_error: %@", error);
        return;
    }
    
    NSString *payload = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSLog(@"palabra_set_task: %@", payload);
    
    NSURLSessionWebSocketMessage *wsMsg = [[NSURLSessionWebSocketMessage alloc] initWithString:payload];
    [self.webSocket sendMessage:wsMsg completionHandler:^(NSError *error) {
        if (error) {
            NSLog(@"palabra_send_error: %@", error);
        }
    }];
}

- (void)handleMessage:(NSString *)text {
    NSError *error;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0
                                                           error:&error];
    if (error) {
        NSLog(@"palabra_parse_error: %@", error);
        return;
    }
    
    NSString *type = json[@"message_type"] ?: @"";
    
    if ([type isEqualToString:@"output_audio_data"]) {
        NSDictionary *data = json[@"data"];
        NSString *audioBase64 = data[@"data"] ?: @"";
        if (audioBase64.length > 0) {
            NSData *audioData = [[NSData alloc] initWithBase64EncodedString:audioBase64 options:0];
            [self playAudio:audioData];
        }
    } else if ([type containsString:@"transcription"]) {
        NSDictionary *data = json[@"data"];
        NSDictionary *transcription = data[@"transcription"];
        if (transcription) {
            NSString *text = transcription[@"text"] ?: @"";
            NSString *lang = transcription[@"language"] ?: @"";
            BOOL isFinal = ![type isEqualToString:@"partial_transcription"];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self notifyTranscription:text language:lang isFinal:isFinal];
            });
        }
    } else if ([type isEqualToString:@"error"]) {
        NSDictionary *data = json[@"data"];
        NSString *desc = data[@"desc"] ?: @"unknown";
        NSLog(@"palabra_error: %@", desc);
        NSError *err = [NSError errorWithDomain:@"PalabraClient" code:500 userInfo:@{NSLocalizedDescriptionKey: desc}];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self notifyError:err];
        });
    }
}

- (void)playAudio:(NSData *)audioData {
    if (!self.translating || !self.playerNode) return;
    
    AVAudioFrameCount frameCount = (AVAudioFrameCount)(audioData.length / 2);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.audioFormat frameCapacity:frameCount];
    buffer.frameLength = frameCount;
    
    memcpy(buffer.int16ChannelData[0], audioData.bytes, audioData.length);
    
    [self.playerNode scheduleBuffer:buffer completionHandler:nil];
}

- (void)stop {
    if (!self.translating) return;
    
    self.translating = NO;
    self.connected = NO;
    
    if (self.remoteTrack) {
        [self.remoteTrack removeRenderer:self];
        self.remoteTrack.source.volume = self.originalVolume;
    }
    
    if (self.webSocket) {
        NSDictionary *endMsg = @{
            @"message_type": @"end_task",
            @"data": @{@"force": @NO}
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:endMsg options:0 error:nil];
        NSString *payload = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:payload];
        [self.webSocket sendMessage:msg completionHandler:nil];
        
        [self.webSocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.webSocket = nil;
    }
    
    [self.playerNode stop];
    [self.audioEngine stop];
    
    [self.bufferLock lock];
    [self.audioBuffer setLength:0];
    [self.bufferLock unlock];
    
    self.remoteTrack = nil;
    [self notifyConnectionState:@"disconnected"];
}

- (void)setTranslatedVolume:(double)volume {
    if (self.playerNode) {
        self.playerNode.volume = volume;
    }
}

- (void)sendAudioToPalabra:(AVAudioPCMBuffer *)buffer {
}

#pragma mark - RTCAudioRenderer

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)buffer {
    if (!self.translating || !self.webSocket) return;
    
    NSData *resampled = [self resampleBuffer:buffer toRate:kSampleRate channels:kChannels];
    
    [self.bufferLock lock];
    [self.audioBuffer appendData:resampled];
    
    while (self.audioBuffer.length >= kChunkBytes) {
        NSData *chunk = [self.audioBuffer subdataWithRange:NSMakeRange(0, kChunkBytes)];
        NSMutableData *remaining = [NSMutableData dataWithData:[self.audioBuffer subdataWithRange:NSMakeRange(kChunkBytes, self.audioBuffer.length - kChunkBytes)]];
        self.audioBuffer = remaining;
        
        [self sendAudioChunk:chunk];
    }
    [self.bufferLock unlock];
}

- (NSData *)resampleBuffer:(AVAudioPCMBuffer *)buffer toRate:(int)dstRate channels:(int)dstChannels {
    int srcRate = (int)buffer.format.sampleRate;
    int srcChannels = (int)buffer.format.channelCount;
    int srcSamples = (int)buffer.frameLength;
    
    if (srcRate == dstRate && srcChannels == dstChannels) {
        if (buffer.format.commonFormat == AVAudioPCMFormatInt16) {
            return [NSData dataWithBytes:buffer.int16ChannelData[0] length:srcSamples * 2];
        }
    }
    
    float *srcData;
    if (buffer.format.commonFormat == AVAudioPCMFormatFloat32) {
        srcData = buffer.floatChannelData[0];
    } else {
        return [NSData data];
    }
    
    float *monoSrc = srcData;
    float *monoBuffer = NULL;
    if (srcChannels == 2 && buffer.floatChannelData[1]) {
        monoBuffer = malloc(srcSamples * sizeof(float));
        for (int i = 0; i < srcSamples; i++) {
            monoBuffer[i] = (buffer.floatChannelData[0][i] + buffer.floatChannelData[1][i]) / 2.0f;
        }
        monoSrc = monoBuffer;
    }
    
    int dstSamples = (int)((long)srcSamples * dstRate / srcRate);
    int16_t *dstData = malloc(dstSamples * sizeof(int16_t));
    
    for (int i = 0; i < dstSamples; i++) {
        float srcIdx = (float)i * (srcSamples - 1) / (dstSamples - 1);
        int idx0 = (int)srcIdx;
        int idx1 = MIN(idx0 + 1, srcSamples - 1);
        float frac = srcIdx - idx0;
        float sample = monoSrc[idx0] * (1 - frac) + monoSrc[idx1] * frac;
        dstData[i] = (int16_t)(sample * 32767.0f);
    }
    
    if (monoBuffer) free(monoBuffer);
    
    NSData *result = [NSData dataWithBytes:dstData length:dstSamples * 2];
    free(dstData);
    return result;
}

- (void)sendAudioChunk:(NSData *)chunk {
    if (!self.webSocket || !self.connected) return;
    
    NSString *base64 = [chunk base64EncodedStringWithOptions:0];
    NSDictionary *msg = @{
        @"message_type": @"input_audio_data",
        @"data": @{
            @"data": base64
        }
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    NSString *payload = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSURLSessionWebSocketMessage *wsMsg = [[NSURLSessionWebSocketMessage alloc] initWithString:payload];
    [self.webSocket sendMessage:wsMsg completionHandler:nil];
}

#pragma mark - Notifications

- (void)notifyConnectionState:(NSString *)state {
    if ([self.delegate respondsToSelector:@selector(palabraDidChangeConnectionState:)]) {
        [self.delegate palabraDidChangeConnectionState:state];
    }
}

- (void)notifyError:(NSError *)error {
    if ([self.delegate respondsToSelector:@selector(palabraDidFailWithError:)]) {
        [self.delegate palabraDidFailWithError:error];
    }
}

- (void)notifyTranscription:(NSString *)text language:(NSString *)lang isFinal:(BOOL)isFinal {
    if ([self.delegate respondsToSelector:@selector(palabraDidReceiveTranscription:)]) {
        [self.delegate palabraDidReceiveTranscription:@{
            @"text": text,
            @"language": lang,
            @"isFinal": @(isFinal)
        }];
    }
}

@end
