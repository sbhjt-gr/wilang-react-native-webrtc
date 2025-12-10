#import "PalabraAudioSink.h"
#import "PalabraClient.h"

@implementation PalabraAudioSink

- (instancetype)initWithClient:(PalabraClient *)client {
    self = [super init];
    if (self) {
        _client = client;
    }
    return self;
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer {
    [self.client sendAudioToPalabra:pcmBuffer];
}

@end
