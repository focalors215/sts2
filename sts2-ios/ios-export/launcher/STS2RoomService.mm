#import "STS2RoomService.h"
#import "STS2FrpTunnel.h"
#import "STS2Log.h"
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
- (NSInteger)serverPort { return STS2_FRP_DEFAULT_SERVER_PORT; }
- (NSString *)defaultToken { return STS2_FRP_DEFAULT_TOKEN; }

- (NSString *)gameVersion {
    NSData *data = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"release_info" withExtension:@"json"]];
    NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [info isKindOfClass:NSDictionary.class] && [info[@"version"] isKindOfClass:NSString.class] ? info[@"version"] : @"unknown";
}

+ (NSArray<NSDictionary *> *)roomsFromScanData:(NSData *)data {
    NSArray *found = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<NSDictionary *> *rooms = [NSMutableArray array];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
    for (NSDictionary *entry in [found isKindOfClass:NSArray.class] ? found : @[]) {
        NSDictionary *info = [entry isKindOfClass:NSDictionary.class] ? entry[@"info"] : nil;
        NSNumber *slot = [entry isKindOfClass:NSDictionary.class] ? entry[@"slot"] : nil;
        if (![info isKindOfClass:NSDictionary.class] || ![slot isKindOfClass:NSNumber.class]) continue;
        NSInteger index = slot.integerValue;
        if (index < 0 || index >= kSlotCount || [seen containsIndex:(NSUInteger)index]) continue;
        [seen addIndex:(NSUInteger)index];
        NSMutableDictionary *room = [info mutableCopy];
        room[@"slot"] = @(index);
        // The joinable port is derived from the slot, never trusted from the card.
        room[@"port"] = @(kFirstGamePort + index);
        if (![room[@"name"] isKindOfClass:NSString.class] || ![room[@"name"] length]) room[@"name"] = @"未命名房间";
        if (![room[@"version"] isKindOfClass:NSString.class] || ![room[@"version"] length]) room[@"version"] = @"unknown";
        NSString *platform = [room[@"platform"] isKindOfClass:NSString.class] ? [room[@"platform"] lowercaseString] : @"";
        room[@"platform"] = [@[@"android", @"windows", @"ios"] containsObject:platform] ? platform : @"unknown";
        if (![room[@"continuing"] isKindOfClass:NSNumber.class]) room[@"continuing"] = @NO;
        [rooms addObject:room];
    }
    [rooms sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"slot"] compare:b[@"slot"]]; }];
    return rooms;
}

+ (NSDictionary *)roomCardWithNickname:(NSString *)nickname version:(NSString *)version continuing:(BOOL)continuing
                                  slot:(NSInteger)slot created:(NSDate *)created {
    return @{
        @"v": @1,
        @"name": [NSString stringWithFormat:@"%@的房间", nickname],
        @"host": nickname,
        @"version": version,
        @"continuing": @(continuing),
        @"created": @((long long)created.timeIntervalSince1970),
        @"slot": @(slot),
        @"port": @(kFirstGamePort + slot),
        @"platform": @"ios",
    };
}

+ (NSString *)platformLabel:(id)platform {
    if ([platform isEqual:@"android"]) return @"Android";
    if ([platform isEqual:@"windows"]) return @"Windows";
    if ([platform isEqual:@"ios"]) return @"iPad";
    return @"未知平台";
}

// Runs on self.queue.
- (NSArray<NSDictionary *> *)scan {
    if (!self.server.length) return @[];
    char *raw = Sts2RoomScan((char *)self.server.UTF8String, (int)kFirstCardPort, (int)kSlotCount, kScanTimeoutMs);
    NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
    free(raw);
    NSArray *rooms = [STS2RoomService roomsFromScanData:data];
    STS2LogI(STS2LogTagOnline, @"扫描 %ld 个槽位，找到 %lu 个房间", (long)kSlotCount, (unsigned long)rooms.count);
    return rooms;
}

- (void)scanRooms:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        NSArray *rooms = [self scan];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(rooms); });
    });
}

- (void)createRoomWithNickname:(NSString *)nickname token:(NSString *)token localPort:(NSInteger)localPort continuing:(BOOL)continuing
                    completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!self.server.length) {
        completion(nil, [NSError errorWithDomain:@"STS2Room" code:1 userInfo:@{NSLocalizedDescriptionKey: @"这个版本没有配置联机服务器（STS2FrpDefaults.h 中的 STS2_FRP_DEFAULT_SERVER）。"}]);
        return;
    }
    if (!token.length) {
        completion(nil, [NSError errorWithDomain:@"STS2Room" code:4 userInfo:@{NSLocalizedDescriptionKey: @"开房需要 frp 令牌，请向服务器管理员索取。"}]);
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
            [self trySlots:candidates nickname:nickname token:token localPort:localPort continuing:continuing completion:completion];
        });
    });
}

// A slot can be taken between scan and registration; fall through to the next one.
- (void)trySlots:(NSArray<NSNumber *> *)slots nickname:(NSString *)nickname token:(NSString *)token localPort:(NSInteger)localPort continuing:(BOOL)continuing
      completion:(void (^)(NSDictionary *, NSError *))completion {
    NSInteger slot = slots.firstObject.integerValue;
    NSDictionary *room = [STS2RoomService roomCardWithNickname:nickname version:self.gameVersion continuing:continuing slot:slot created:NSDate.date];
    STS2LogI(STS2LogTagOnline, @"尝试槽位 %ld：UDP %ld / TCP %ld", (long)slot, (long)(kFirstGamePort + slot), (long)(kFirstCardPort + slot));
    NSData *card = [NSJSONSerialization dataWithJSONObject:room options:0 error:nil];
    int cardPort = Sts2RoomServe((char *)[[NSString alloc] initWithData:card encoding:NSUTF8StringEncoding].UTF8String);
    if (cardPort <= 0) {
        STS2LogE(STS2LogTagOnline, nil, @"无法启动房间信息服务（Sts2RoomServe 返回 %d）", cardPort);
        completion(nil, [NSError errorWithDomain:@"STS2Room" code:3 userInfo:@{NSLocalizedDescriptionKey: @"无法启动房间信息服务。"}]);
        return;
    }
    NSArray *proxies = @[
        @{@"name": [NSString stringWithFormat:@"sts2-room-%ld-game", (long)slot], @"type": @"udp", @"localPort": @(localPort), @"remotePort": @(kFirstGamePort + slot)},
        @{@"name": [NSString stringWithFormat:@"sts2-room-%ld-card", (long)slot], @"type": @"tcp", @"localPort": @(cardPort), @"remotePort": @(kFirstCardPort + slot)},
    ];
    [STS2FrpTunnel.shared startWithServer:self.server serverPort:self.serverPort token:token proxies:proxies completion:^(NSError *error) {
        if (!error) { STS2LogI(STS2LogTagOnline, @"房间已发布：槽位 %ld", (long)slot); completion(room, nil); return; }
        STS2LogW(STS2LogTagFrp, @"槽位 %ld 注册失败: %@", (long)slot, error.localizedDescription);
        NSString *message = error.localizedDescription;
        BOOL taken = [message rangeOfString:@"占用"].location != NSNotFound || [message rangeOfString:@"already"].location != NSNotFound;
        if (taken && slots.count > 1) {
            [self trySlots:[slots subarrayWithRange:NSMakeRange(1, slots.count - 1)] nickname:nickname token:token localPort:localPort continuing:continuing completion:completion];
            return;
        }
        Sts2RoomStopServe();
        completion(nil, error);
    }];
}
@end
