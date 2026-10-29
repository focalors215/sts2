#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// In-process frp client (official frp library, see src/FrpBridge).
@interface STS2FrpTunnel : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
/// Starts the tunnel with proxies ({name, type, localPort, remotePort}) and calls
/// completion on the main queue once every proxy is registered on the server
/// (error == nil) or one failed. Stops any previous tunnel first.
- (void)startWithServer:(NSString *)server serverPort:(NSInteger)serverPort token:(NSString *)token
                proxies:(NSArray<NSDictionary *> *)proxies
             completion:(void (^)(NSError *_Nullable error))completion;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
