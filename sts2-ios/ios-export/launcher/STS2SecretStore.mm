#import "STS2SecretStore.h"
#import "STS2Log.h"
#import <Security/Security.h>

NSString *const STS2SecretFrpToken = @"frp.token";
NSString *const STS2SecretWebDavPassword = @"webdav.password";
NSString *const STS2SecretNexusApiKey = @"nexus.apiKey";
NSString *const STS2SecretLlmApiKey = @"llm.apiKey";
static NSString *const kService = @"com.sts2.launcher.secrets";

static __attribute__((unused)) NSMutableDictionary *BaseQuery(NSString *key) {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: kService,
              (__bridge id)kSecAttrAccount: key} mutableCopy];
}

#if defined(STS2_SECRET_STORE_MEMORY)
// 宿主测试：不碰开发机的登录钥匙串。
static NSMutableDictionary *MemoryStore(void) { static NSMutableDictionary *store; static dispatch_once_t once; dispatch_once(&once, ^{ store = [NSMutableDictionary dictionary]; }); return store; }
@implementation STS2SecretStore
+ (NSString *)secretForKey:(NSString *)key { NSString *v = MemoryStore()[key]; [STS2Log registerSecret:v]; return v; }
+ (BOOL)setSecret:(NSString *)value forKey:(NSString *)key error:(NSError **)error {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) { MemoryStore()[key] = trimmed; [STS2Log registerSecret:trimmed]; } else [MemoryStore() removeObjectForKey:key];
    return YES;
}
+ (void)registerAllForRedaction {}
@end
#else
@implementation STS2SecretStore
+ (NSString *)secretForKey:(NSString *)key {
    NSMutableDictionary *query = BaseQuery(key);
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return nil;
    if (status != errSecSuccess) {
        STS2LogW(STS2LogTagApp, @"读取钥匙串项目 %@ 失败（OSStatus %d）", key, (int)status);
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [STS2Log registerSecret:value];
    return value;
}

+ (BOOL)setSecret:(NSString *)value forKey:(NSString *)key error:(NSError **)error {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)BaseQuery(key));
    if (status != errSecSuccess && status != errSecItemNotFound) goto fail;
    if (!trimmed.length) return YES;
    {
        [STS2Log registerSecret:trimmed];
        NSMutableDictionary *item = BaseQuery(key);
        item[(__bridge id)kSecValueData] = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status == errSecSuccess) return YES;
    }
fail:
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"无法保存到钥匙串（OSStatus %d）。", (int)status]}];
    STS2LogE(STS2LogTagApp, error ? *error : nil, @"保存钥匙串项目 %@ 失败", key);
    return NO;
}

+ (void)registerAllForRedaction {
    for (NSString *key in @[STS2SecretFrpToken, STS2SecretWebDavPassword, STS2SecretNexusApiKey, STS2SecretLlmApiKey]) [self secretForKey:key];
}
@end
#endif
