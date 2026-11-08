#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Online rooms on the central frp server（规范 §3.2）. Slot i maps the host's game UDP port to
/// server UDP (33771 + i) and publishes a JSON room card v1 on server TCP (34771 + i).
/// Room dictionaries: v, name, host, version, continuing, created, slot, port, platform.
@interface STS2RoomService : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) NSString *server;
@property(nonatomic, readonly) NSInteger serverPort;
/// Version from the bundled release_info.json, or "unknown".
@property(nonatomic, readonly) NSString *gameVersion;
/// 个人构建可在 STS2FrpDefaults.h 预置令牌；公开构建为空，开房时向用户索要。
@property(nonatomic, readonly) NSString *defaultToken;
- (void)scanRooms:(void (^)(NSArray<NSDictionary *> *rooms))completion;
/// Takes a free slot, publishes the room card and starts the tunnel.
- (void)createRoomWithNickname:(NSString *)nickname token:(NSString *)token localPort:(NSInteger)localPort continuing:(BOOL)continuing
                    completion:(void (^)(NSDictionary *_Nullable room, NSError *_Nullable error))completion;

/// 纯函数：Sts2RoomScan 返回的 [{slot, info}] → 规范化后的房间列表（端口由槽位推出，按槽位排序）。
+ (NSArray<NSDictionary *> *)roomsFromScanData:(nullable NSData *)data;
/// 纯函数：房间卡 v1（含 platform = "ios"）。
+ (NSDictionary *)roomCardWithNickname:(NSString *)nickname version:(NSString *)version continuing:(BOOL)continuing
                                  slot:(NSInteger)slot created:(NSDate *)created;
/// android → Android，windows → Windows，ios → iPad，其他 → 未知平台。
+ (NSString *)platformLabel:(nullable id)platform;
@end

NS_ASSUME_NONNULL_END
