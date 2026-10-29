#import "STS2RoomService.h"
#import "STS2FrpTunnel.h"
#include <stdlib.h>

// Personal frp server values stay out of git: copy STS2FrpDefaults.example.h.
#if __has_include("STS2FrpDefaults.h")
#import "STS2FrpDefaults.h"
#endif
#ifndef STS2_FRP_DEFAULT_SERVER
#define STS2_FRP_DEFAULT_SERVER @""
#define STS2_FRP_DEFAULT_SERVER_PORT 7000
#define STS2_FRP_DEFAULT_TOKEN @""
#endif

// Exported by libfrpbridge.a (src/FrpBridge/bridge.go). Returned strings are malloc'ed.
extern "C" {
int Sts2RoomServe(char *info);
void Sts2RoomStopServe(void);
char *Sts2RoomScan(char *server, int firstPort, int count, int timeoutMs);
}

static const NSInteger kFirstGamePort = 33771;  // server UDP, frps allowPorts
static const NSInteger kFirstCardPort = 34771;  // server TCP, frps allowPorts
static const NSInteger kSlotCount = 20;
static const int kScanTimeoutMs = 2500;

@interface STS2RoomService ()
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation STS2RoomService
+ (instancetype)shared {
    static STS2RoomService *service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [STS2RoomService new]; service.queue = dispatch_queue_create("com.sts2.launcher.rooms", DISPATCH_QUEUE_SERIAL); });
    return service;
}

- (NSString *)server { return STS2_FRP_DEFAULT_SERVER; }

- (NSString *)gameVersion {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"release_info" withExtension:@"json"]];
    NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [info isKindOfClass:NSDictionary.class] && [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"unknown";
}

// Runs on self.queue.
- (NSArray<NSDictionary *> *)scan {
    if (!self.server.length) return @[];
    char *raw = Sts2RoomScan((char *)self.server.UTF8String, (int)kFirstCardPort, (int)kSlotCount, kScanTimeoutMs);
    NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
    free(raw);
    NSArray *found = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<NSDictionary *> *rooms = [NSMutableArray array];
    for (NSDictionary *entry in [found isKindOfClass:NSArray.class] ? found : @[]) {
        NSDictionary *info = [entry isKindOfClass:NSDictionary.class] ? entry[@"info"] : nil;
        NSNumber *slot = [entry isKindOfClass:NSDictionary.class] ? entry[@"slot"] : nil;
        if (![info isKindOfClass:NSDictionary.class] || ![slot isKindOfClass:NSNumber.class]) continue;
        NSMutableDictionary *room = [info mutableCopy];
        room[@"slot"] = slot;
        // The joinable port is derived from the slot, never trusted from the card.
        room[@"port"] = @(kFirstGamePort + slot.integerValue);
        if (![room[@"name"] isKindOfClass:NSString.class]) room[@"name"] = @"未命名房间";
        if (![room[@"version"] isKindOfClass:NSString.class]) room[@"version"] = @"unknown";
        [rooms addObject:room];
    }
    [rooms sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"slot"] compare:b[@"slot"]]; }];
    return rooms;
}

- (void)scanRooms:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        NSArray *rooms = [self scan];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(rooms); });
    });
}

- (void)createRoomWithNickname:(NSString *)nickname localPort:(NSInteger)localPort continuing:(BOOL)continuing
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!self.server.length) {
        completion(nil, [NSError errorWithDomain:@"STS2Room" code:1 userInfo:@{NSLocalizedDescriptionKey: @"未配置联机服务器（STS2FrpDefaults.h）。"}]);
        return;
    }
    dispatch_async(self.queue, ^{
        NSMutableIndexSet *free = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, kSlotCount)];
        for (NSDictionary *room in [self scan]) [free removeIndex:[room[@"slot"] unsignedIntegerValue]];
        NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
        [free enumerateIndexesUsingBlock:^(NSUInteger slot, BOOL *stop) { [candidates addObject:@(slot)]; *stop = candidates.count >= 3; }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!candidates.count) {
                completion(nil, [NSError errorWithDomain:@"STS2Room" code:2 userInfo:@{NSLocalizedDescriptionKey: @"服务器房间已满，请稍后再试。"}]);
                return;
            }
            [self trySlots:candidates nickname:nickname localPort:localPort continuing:continuing completion:completion];
        });
    });
}

// A slot can be taken between scan and registration; fall through to the next one.
- (void)trySlots:(NSArray<NSNumber *> *)slots nickname:(NSString *)nickname localPort:(NSInteger)localPort continuing:(BOOL)continuing
      completion:(void (^)(NSDictionary *, NSError *))completion {
    NSInteger slot = slots.firstObject.integerValue;
    NSDictionary *room = @{
        @"v": @1,
        @"name": [NSString stringWithFormat:@"%@的房间", nickname],
        @"host": nickname,
        @"version": self.gameVersion,
        @"continuing": @(continuing),
        @"created": @((long long)NSDate.date.timeIntervalSince1970),
        @"slot": @(slot),
        @"port": @(kFirstGamePort + slot),
    };
    NSData *card = [NSJSONSerialization dataWithJSONObject:room options:0 error:nil];
    int cardPort = Sts2RoomServe((char *)[[NSString alloc] initWithData:card encoding:NSUTF8StringEncoding].UTF8String);
    if (cardPort <= 0) {
        completion(nil, [NSError errorWithDomain:@"STS2Room" code:3 userInfo:@{NSLocalizedDescriptionKey: @"无法启动房间信息服务。"}]);
        return;
    }
    NSArray *proxies = @[
        @{@"name": [NSString stringWithFormat:@"sts2-room-%ld-game", (long)slot], @"type": @"udp", @"localPort": @(localPort), @"remotePort": @(kFirstGamePort + slot)},
        @{@"name": [NSString stringWithFormat:@"sts2-room-%ld-card", (long)slot], @"type": @"tcp", @"localPort": @(cardPort), @"remotePort": @(kFirstCardPort + slot)},
    ];
    [STS2FrpTunnel.shared startWithServer:self.server serverPort:STS2_FRP_DEFAULT_SERVER_PORT token:STS2_FRP_DEFAULT_TOKEN proxies:proxies completion:^(NSError *error) {
        if (!error) { completion(room, nil); return; }
        NSString *message = error.localizedDescription;
        BOOL taken = [message rangeOfString:@"占用"].location != NSNotFound || [message rangeOfString:@"already"].location != NSNotFound;
        if (taken && slots.count > 1) {
            [self trySlots:[slots subarrayWithRange:NSMakeRange(1, slots.count - 1)] nickname:nickname localPort:localPort continuing:continuing completion:completion];
            return;
        }
        Sts2RoomStopServe();
        completion(nil, error);
    }];
}
@end
