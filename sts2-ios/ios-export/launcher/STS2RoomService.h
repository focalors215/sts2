#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Online rooms on the central frp server. Slot i maps the host's game UDP port to
/// server UDP (kFirstGamePort + i) and publishes a JSON room card on server TCP
/// (kFirstCardPort + i). Room dictionaries: name, host, version, port, created, slot.
@interface STS2RoomService : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) NSString *server;
/// Version from the bundled release_info.json, or "unknown".
@property(nonatomic, readonly) NSString *gameVersion;
- (void)scanRooms:(void (^)(NSArray<NSDictionary *> *rooms))completion;
/// Takes a free slot, publishes the room card and starts the tunnel.
- (void)createRoomWithNickname:(NSString *)nickname localPort:(NSInteger)localPort continuing:(BOOL)continuing
                    completion:(void (^)(NSDictionary *_Nullable room, NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
