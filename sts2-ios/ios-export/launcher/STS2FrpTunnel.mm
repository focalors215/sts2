#import "STS2FrpTunnel.h"
#include <stdlib.h>

// Exported by libfrpbridge.a (src/FrpBridge/bridge.go). Returned strings are malloc'ed.
extern "C" {
char *Sts2FrpStart(char *path);
char *Sts2FrpStatus(char *proxyName);
void Sts2FrpStop(void);
}

static const NSTimeInterval kStartTimeout = 20;

static NSString *TakeCString(char *value) {
    if (!value) return nil;
    NSString *result = [NSString stringWithUTF8String:value];
    free(value);
    return result;
}

// TOML basic string: escape backslash, quote and control characters.
static NSString *TomlString(NSString *value) {
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (c == '"' || c == '\\') [out appendFormat:@"\\%C", c];
        else if (c < 0x20 || c == 0x7f) [out appendFormat:@"\\u%04X", c];
        else [out appendFormat:@"%C", c];
    }
    [out appendString:@"\""];
    return out;
}

static NSError *TunnelError(NSString *message) {
    // Prefix a Chinese hint for the common frp failures; keep frp's own text for diagnosis.
    NSArray<NSArray<NSString *> *> *hints = @[
        @[@"token", @"令牌（token）与服务器不一致。"],
        @[@"port not allowed", @"服务器不允许该远程端口（检查 frps 的 allowPorts）。"],
        @[@"already", @"远程端口或映射名已被占用：可能有其他房主在用，或上次连接未释放（约 1 分钟后重试）。"],
        @[@"port unavailable", @"服务器上该远程端口已被占用。"],
        @[@"connection refused", @"连不上 frp 服务器：检查地址、端口，以及服务器防火墙/安全组。"],
        @[@"EOF", @"连接被服务器或网络中断：检查端口是否为 frps 端口、是否被代理软件拦截。"],
        @[@"timeout", @"连接 frp 服务器超时：检查网络和服务器防火墙/安全组。"],
    ];
    for (NSArray<NSString *> *hint in hints)
        if ([message rangeOfString:hint[0] options:NSCaseInsensitiveSearch].location != NSNotFound) {
            message = [NSString stringWithFormat:@"%@\n（%@）", hint[1], message];
            break;
        }
    return [NSError errorWithDomain:@"STS2FrpTunnel" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface STS2FrpTunnel ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(atomic) NSUInteger generation; // read on the frp queue, bumped on main
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@end

@implementation STS2FrpTunnel
+ (instancetype)shared {
    static STS2FrpTunnel *tunnel;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tunnel = [STS2FrpTunnel new]; tunnel.queue = dispatch_queue_create("com.sts2.launcher.frp", DISPATCH_QUEUE_SERIAL); });
    return tunnel;
}

- (NSURL *)configURL:(NSError **)error {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:error];
    NSURL *directory = [support URLByAppendingPathComponent:@"frp" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return [directory URLByAppendingPathComponent:@"frpc.toml"];
}

- (void)startWithServer:(NSString *)server serverPort:(NSInteger)serverPort token:(NSString *)token
                proxies:(NSArray<NSDictionary *> *)proxies
             completion:(void (^)(NSError *))completion {
    NSUInteger generation = ++self.generation;
    void (^finish)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return; // superseded by stop/start
            self.running = error == nil;
            completion(error);
        });
    };
    dispatch_async(self.queue, ^{
        Sts2FrpStop();
        NSError *error = nil;
        NSURL *url = [self configURL:&error];
        if (!url) { finish(error); return; }
        NSURL *log = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"frpc.log"];
        NSMutableString *toml = [NSMutableString stringWithFormat:
            @"serverAddr = %@\nserverPort = %ld\nloginFailExit = true\n"
             "auth.method = \"token\"\nauth.token = %@\n"
             "log.to = %@\nlog.level = \"info\"\nlog.maxDays = 1\n",
            TomlString(server), (long)serverPort, TomlString(token), TomlString(log.path)];
        for (NSDictionary *proxy in proxies)
            [toml appendFormat:@"\n[[proxies]]\nname = %@\ntype = %@\nlocalIP = \"127.0.0.1\"\nlocalPort = %ld\nremotePort = %ld\n",
                TomlString(proxy[@"name"]), TomlString(proxy[@"type"]), (long)[proxy[@"localPort"] integerValue], (long)[proxy[@"remotePort"] integerValue]];
        // The file holds the token; keep it encrypted while the device is locked.
        if (![toml writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) { finish(error); return; }
        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:url.path error:nil];
        NSString *startError = TakeCString(Sts2FrpStart((char *)url.fileSystemRepresentation));
        if (startError) { finish(TunnelError([@"frp 配置无效：" stringByAppendingString:startError])); return; }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kStartTimeout];
        while (generation == self.generation) {
            NSUInteger running = 0;
            for (NSDictionary *proxy in proxies) {
                NSString *json = TakeCString(Sts2FrpStatus((char *)[proxy[@"name"] UTF8String]));
                NSDictionary *status = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
                NSString *state = [status[@"state"] isKindOfClass:NSString.class] ? status[@"state"] : @"error";
                if ([state isEqual:@"running"]) { running++; continue; }
                if (![state isEqual:@"starting"] || deadline.timeIntervalSinceNow < 0) {
                    NSString *detail = [status[@"error"] isKindOfClass:NSString.class] ? status[@"error"] : @"连接服务器超时";
                    Sts2FrpStop();
                    finish(TunnelError(detail));
                    return;
                }
            }
            if (running == proxies.count) { finish(nil); return; }
            [NSThread sleepForTimeInterval:0.3];
        }
    });
}

- (void)stop {
    self.generation++;
    self.running = NO;
    dispatch_async(self.queue, ^{ Sts2FrpStop(); });
}
@end
