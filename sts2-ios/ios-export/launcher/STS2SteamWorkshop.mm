#import "STS2SteamWorkshop.h"
#import "STS2Log.h"
#import "STS2ZipArchive.h"
#import <CommonCrypto/CommonCrypto.h>
#include <dlfcn.h>
#include <string>
#include <vector>

const NSUInteger STS2WorkshopAppId = 2868840;
NSString *const STS2WorkshopErrorDomain = @"STS2Workshop";
static NSString *const kSupplyStation = @"https://workshop.apricityx.top/api/downloads/browser/";
static const unsigned long long kMaxItemBytes = 1024ull * 1024 * 1024;
static const NSUInteger kChunkConcurrency = 4;
static const NSUInteger kMaxJsonBytes = 1024 * 1024;

static NSError *WorkshopError(NSString *message) {
    return [NSError errorWithDomain:STS2WorkshopErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - LZMA (system liblzma, loaded at runtime)

// liblzma 5.x 公开 ABI 的 lzma_stream；iOS SDK 只带 .tbd 不带头文件，运行时从系统共享缓存 dlopen。
typedef struct {
    const uint8_t *next_in; size_t avail_in; uint64_t total_in;
    uint8_t *next_out; size_t avail_out; uint64_t total_out;
    const void *allocator; void *internal;
    void *reserved_ptr1, *reserved_ptr2, *reserved_ptr3, *reserved_ptr4;
    uint64_t reserved_int1, reserved_int2; size_t reserved_int3, reserved_int4;
    int reserved_enum1, reserved_enum2;
} STS2LzmaStream;
typedef int (*LzmaAloneDecoderFn)(STS2LzmaStream *, uint64_t);
typedef int (*LzmaCodeFn)(STS2LzmaStream *, int);
typedef void (*LzmaEndFn)(STS2LzmaStream *);
static LzmaAloneDecoderFn gLzmaAlone; static LzmaCodeFn gLzmaCode; static LzmaEndFn gLzmaEnd;

static BOOL LoadLzma(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/liblzma.5.dylib", RTLD_LAZY) ?: dlopen("/usr/lib/liblzma.dylib", RTLD_LAZY);
        if (!handle) return;
        gLzmaAlone = (LzmaAloneDecoderFn)dlsym(handle, "lzma_alone_decoder");
        gLzmaCode = (LzmaCodeFn)dlsym(handle, "lzma_code");
        gLzmaEnd = (LzmaEndFn)dlsym(handle, "lzma_end");
    });
    return gLzmaAlone && gLzmaCode && gLzmaEnd;
}

// Steam VZip（"VZa"）：7 字节头 + 5 字节 LZMA 属性 + 原始 LZMA 流 + 10 字节尾（CRC、原始大小、"zv"）。
// 转成 LZMA-alone 头（属性 + 字典 + 64 位大小）交给 liblzma。
static NSData *DecompressVZip(NSData *raw, NSError **error) {
    const uint8_t *b = (const uint8_t *)raw.bytes;
    if (raw.length < 12 + 10 || b[0] != 'V' || b[1] != 'Z' || b[2] != 'a') { if (error) *error = WorkshopError(@"VZip 头无效"); return nil; }
    const uint8_t *footer = b + raw.length - 10;
    if (footer[8] != 'z' || footer[9] != 'v') { if (error) *error = WorkshopError(@"VZip 尾无效"); return nil; }
    uint32_t size = (uint32_t)footer[4] | ((uint32_t)footer[5] << 8) | ((uint32_t)footer[6] << 16) | ((uint32_t)footer[7] << 24);
    if (size > 64 * 1024 * 1024) { if (error) *error = WorkshopError(@"分块解压后过大"); return nil; }
    if (!LoadLzma()) { if (error) *error = WorkshopError(@"系统缺少 LZMA 解码库，无法解压该条目"); return nil; }
    std::vector<uint8_t> input(13 + raw.length - 12 - 10);
    memcpy(input.data(), b + 7, 5); // props + dictionary size
    uint64_t length = size;
    for (int i = 0; i < 8; i++) input[5 + i] = (uint8_t)(length >> (8 * i));
    memcpy(input.data() + 13, b + 12, raw.length - 12 - 10);
    NSMutableData *output = [NSMutableData dataWithLength:size];
    STS2LzmaStream stream = {};
    if (gLzmaAlone(&stream, UINT64_MAX) != 0) { if (error) *error = WorkshopError(@"LZMA 解码器初始化失败"); return nil; }
    stream.next_in = input.data(); stream.avail_in = input.size();
    stream.next_out = (uint8_t *)output.mutableBytes; stream.avail_out = size;
    int ret = gLzmaCode(&stream, 3 /* LZMA_FINISH */);
    uint64_t produced = stream.total_out;
    gLzmaEnd(&stream);
    if ((ret != 0 && ret != 1) || produced != size) { if (error) *error = WorkshopError([NSString stringWithFormat:@"LZMA 解压失败（%d）", ret]); return nil; }
    return output;
}

#pragma mark - Protobuf

struct PBReader {
    const uint8_t *p, *end;
    bool ok = true;
    uint64_t varint() { uint64_t v = 0; for (int s = 0; s < 64 && p < end; s += 7) { uint8_t c = *p++; v |= (uint64_t)(c & 0x7f) << s; if (!(c & 0x80)) return v; } ok = false; return 0; }
    uint32_t fixed32() { if (end - p < 4) { ok = false; return 0; } uint32_t v = p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); p += 4; return v; }
    NSData *bytes() { uint64_t n = varint(); if (!ok || n > (uint64_t)(end - p)) { ok = false; return nil; } NSData *d = [NSData dataWithBytes:p length:(NSUInteger)n]; p += n; return d; }
    void skip(int wire) {
        switch (wire) { case 0: varint(); break; case 1: if (end - p < 8) ok = false; else p += 8; break;
            case 2: { uint64_t n = varint(); if (n > (uint64_t)(end - p)) ok = false; else p += n; break; }
            case 5: if (end - p < 4) ok = false; else p += 4; break; default: ok = false; }
    }
};
static NSString *PBString(NSData *d) {
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@" %C", (unichar)0]]] ?: @"";
}

static NSDictionary *ParseChunk(NSData *data) {
    PBReader r{(const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length};
    NSMutableDictionary *chunk = [@{@"id": [NSData data], @"crc": @0, @"offset": @0, @"original": @0, @"compressed": @0} mutableCopy];
    while (r.ok && r.p < r.end) {
        uint64_t key = r.varint(); int field = (int)(key >> 3), wire = (int)(key & 7);
        if (field == 1 && wire == 2) chunk[@"id"] = r.bytes() ?: [NSData data];
        else if (field == 2 && wire == 5) chunk[@"crc"] = @(r.fixed32());
        else if (field == 3 && wire == 0) chunk[@"offset"] = @(r.varint());
        else if (field == 4 && wire == 0) chunk[@"original"] = @(r.varint());
        else if (field == 5 && wire == 0) chunk[@"compressed"] = @(r.varint());
        else r.skip(wire);
    }
    return r.ok ? chunk : nil;
}

static NSDictionary *ParseMapping(NSData *data) {
    PBReader r{(const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length};
    NSMutableDictionary *file = [@{@"path": @"", @"size": @0, @"flags": @0, @"sha": [NSData data], @"linkTarget": @""} mutableCopy];
    NSMutableArray *chunks = [NSMutableArray array];
    while (r.ok && r.p < r.end) {
        uint64_t key = r.varint(); int field = (int)(key >> 3), wire = (int)(key & 7);
        if (field == 1 && wire == 2) file[@"path"] = PBString(r.bytes());
        else if (field == 2 && wire == 0) file[@"size"] = @(r.varint());
        else if (field == 3 && wire == 0) file[@"flags"] = @(r.varint());
        else if (field == 5 && wire == 2) file[@"sha"] = r.bytes() ?: [NSData data];
        else if (field == 6 && wire == 2) { NSDictionary *chunk = ParseChunk(r.bytes()); if (!chunk) return nil; [chunks addObject:chunk]; }
        else if (field == 7 && wire == 2) file[@"linkTarget"] = PBString(r.bytes());
        else r.skip(wire);
    }
    file[@"chunks"] = chunks;
    return r.ok ? file : nil;
}

#pragma mark - Implementation

@interface STS2NoRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation STS2NoRedirect
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler { completionHandler(nil); }
@end

@interface STS2SteamWorkshop ()
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSession *noRedirect;
@property(nonatomic, strong) NSCache<NSString *, NSData *> *images;
@end

@implementation STS2SteamWorkshop
+ (instancetype)shared {
    static STS2SteamWorkshop *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [STS2SteamWorkshop new];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 30; c.HTTPAdditionalHeaders = @{@"User-Agent": @"Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) STS2iPadLauncher", @"Accept-Language": @"zh-CN,zh;q=0.9,en;q=0.8"};
        shared.session = [NSURLSession sessionWithConfiguration:c];
        NSURLSessionConfiguration *e = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        e.timeoutIntervalForRequest = 60; e.timeoutIntervalForResource = 600; e.URLCache = nil;
        shared.noRedirect = [NSURLSession sessionWithConfiguration:e delegate:[STS2NoRedirect new] delegateQueue:nil];
        shared.images = [NSCache new]; shared.images.totalCostLimit = 48 * 1024 * 1024;
    });
    return shared;
}

#pragma mark Pure helpers

+ (NSString *)itemIdFromInput:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:[?&]id=|^)(\\d{3,20})(?:$|[&#/])" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:trimmed options:0 range:NSMakeRange(0, trimmed.length)];
    return match ? [trimmed substringWithRange:[match rangeAtIndex:1]] : nil;
}

+ (NSArray<NSString *> *)itemIdsFromBrowseHTML:(NSString *)html {
    NSMutableArray *ids = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *pattern in @[@"data-publishedfileid=\"(\\d+)\"", @"sharedfiles/filedetails/\\?id=(\\d+)", @"\"publishedfileid\":\"(\\d+)\""]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        for (NSTextCheckingResult *match in [regex matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
            NSString *identifier = [html substringWithRange:[match rangeAtIndex:1]];
            if (![seen containsObject:identifier]) { [seen addObject:identifier]; [ids addObject:identifier]; }
        }
        if (ids.count) break; // 第一种能匹配就以它的顺序为准
    }
    return ids;
}

+ (NSArray<NSDictionary *> *)itemsFromDetailsJSON:(NSData *)data {
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *details = [root isKindOfClass:NSDictionary.class] && [root[@"response"] isKindOfClass:NSDictionary.class] ? root[@"response"][@"publishedfiledetails"] : nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *d in [details isKindOfClass:NSArray.class] ? details : @[]) {
        if (![d isKindOfClass:NSDictionary.class] || [d[@"result"] integerValue] != 1) continue;
        NSString *identifier = [d[@"publishedfileid"] description];
        if (!identifier.length || [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) continue;
        NSInteger app = [d[@"consumer_app_id"] integerValue];
        if (app && app != (NSInteger)STS2WorkshopAppId) continue;
        NSMutableArray *tags = [NSMutableArray array];
        for (NSDictionary *tag in [d[@"tags"] isKindOfClass:NSArray.class] ? d[@"tags"] : @[]) if ([tag isKindOfClass:NSDictionary.class] && [tag[@"tag"] isKindOfClass:NSString.class]) [tags addObject:tag[@"tag"]];
        NSString *title = [d[@"title"] isKindOfClass:NSString.class] && [d[@"title"] length] ? d[@"title"] : [@"Workshop " stringByAppendingString:identifier];
        [items addObject:@{@"id": identifier, @"title": title,
                           @"description": [d[@"description"] isKindOfClass:NSString.class] ? d[@"description"] : @"",
                           @"preview": [d[@"preview_url"] isKindOfClass:NSString.class] ? d[@"preview_url"] : @"",
                           @"size": @([d[@"file_size"] longLongValue]), @"updated": @([d[@"time_updated"] longLongValue]),
                           @"subscriptions": @([d[@"lifetime_subscriptions"] ?: d[@"subscriptions"] longLongValue]), @"views": @([d[@"views"] longLongValue]),
                           @"creator": [d[@"creator"] description] ?: @"", @"tags": tags}];
    }
    return items;
}

+ (NSArray<NSString *> *)screenshotURLsFromPageHTML:(NSString *)html {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"https://(?:images\\.steamusercontent\\.com|steamuserimages-a\\.akamaihd\\.net)/ugc/[0-9A-Za-z/._-]+" options:0 error:nil];
    NSMutableArray *urls = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSTextCheckingResult *match in [regex matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString *url = [html substringWithRange:match.range];
        NSString *key = [[url componentsSeparatedByString:@"?"].firstObject stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        if ([seen containsObject:key]) continue;
        [seen addObject:key]; [urls addObject:url];
        if (urls.count >= 12) break;
    }
    return urls;
}

+ (uint32_t)steamAdler32:(NSData *)data {
    // Steam 的变体：a 从 0 开始（不是标准 Adler32 的 1）。
    uint32_t a = 0, b = 0;
    const uint8_t *p = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) { a = (a + p[i]) % 65521; b = (b + a) % 65521; }
    return (b << 16) | a;
}

static NSData *AesDecrypt(NSData *data, NSData *key, NSData *iv, BOOL ecb, BOOL padding) {
    size_t outLength = 0;
    NSMutableData *out = [NSMutableData dataWithLength:data.length + kCCBlockSizeAES128];
    CCOptions options = (ecb ? kCCOptionECBMode : 0) | (padding ? kCCOptionPKCS7Padding : 0);
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, options, key.bytes, key.length, iv.bytes, data.bytes, data.length, out.mutableBytes, out.length, &outLength);
    if (status != kCCSuccess) return nil;
    out.length = outLength;
    return out;
}

// Steam 对称加密：先 ECB 解出 IV（前 16 字节），再 CBC + PKCS7 解剩余部分。
static NSData *SteamDecrypt(NSData *data, NSData *key) {
    if (data.length <= 16 || key.length != 32) return nil;
    NSData *iv = AesDecrypt([data subdataWithRange:NSMakeRange(0, 16)], key, nil, YES, NO);
    return iv ? AesDecrypt([data subdataWithRange:NSMakeRange(16, data.length - 16)], key, iv, NO, YES) : nil;
}

+ (NSString *)decryptFilename:(NSString *)encoded key:(NSData *)depotKey {
    NSString *clean = [[encoded componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSData *encrypted = [[NSData alloc] initWithBase64EncodedString:clean options:0];
    NSData *plain = encrypted ? SteamDecrypt(encrypted, depotKey) : nil;
    if (!plain) return nil;
    NSUInteger length = plain.length;
    while (length && ((const uint8_t *)plain.bytes)[length - 1] == 0) length--;
    NSString *name = [[NSString alloc] initWithData:[plain subdataWithRange:NSMakeRange(0, length)] encoding:NSUTF8StringEncoding];
    return [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
}

+ (NSDictionary *)parseManifest:(NSData *)data error:(NSError **)error {
    if (data.length >= 4 && memcmp(data.bytes, "PK\x03\x04", 4) == 0) {
        NSDictionary *entries = STS2ZipReadData(data, error);
        if (entries.count != 1) { if (error && entries) *error = WorkshopError(@"manifest 压缩包内容异常"); return nil; }
        data = entries.allValues.firstObject;
    }
    PBReader r{(const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length};
    NSData *payload = nil, *metadata = nil;
    while (r.ok && r.end - r.p >= 4) {
        uint32_t magic = r.fixed32();
        if (magic == 0x32C415AB) break;
        if (r.end - r.p < 4) { r.ok = false; break; }
        uint32_t length = r.fixed32();
        if (length > (uint64_t)(r.end - r.p)) { r.ok = false; break; }
        NSData *section = [NSData dataWithBytes:r.p length:length];
        r.p += length;
        if (magic == 0x71F617D0) payload = section;
        else if (magic == 0x1F4812BE) metadata = section;
        else if (magic != 0x1B81B817) { if (error) *error = WorkshopError([NSString stringWithFormat:@"未知的 manifest 分段 0x%08x", magic]); return nil; }
    }
    if (!r.ok || !payload || !metadata) { if (error) *error = WorkshopError(@"depot manifest 不完整"); return nil; }
    NSMutableDictionary *result = [@{@"depotId": @0, @"manifestId": @0, @"filenamesEncrypted": @NO} mutableCopy];
    PBReader m{(const uint8_t *)metadata.bytes, (const uint8_t *)metadata.bytes + metadata.length};
    while (m.ok && m.p < m.end) {
        uint64_t key = m.varint(); int field = (int)(key >> 3), wire = (int)(key & 7);
        if (field == 1 && wire == 0) result[@"depotId"] = @(m.varint());
        else if (field == 2 && wire == 0) result[@"manifestId"] = @(m.varint());
        else if (field == 4 && wire == 0) result[@"filenamesEncrypted"] = @(m.varint() != 0);
        else m.skip(wire);
    }
    NSMutableArray *files = [NSMutableArray array];
    PBReader p{(const uint8_t *)payload.bytes, (const uint8_t *)payload.bytes + payload.length};
    while (p.ok && p.p < p.end) {
        uint64_t key = p.varint(); int field = (int)(key >> 3), wire = (int)(key & 7);
        if (field == 1 && wire == 2) { NSDictionary *file = ParseMapping(p.bytes()); if (!file) { p.ok = false; break; } [files addObject:file]; }
        else p.skip(wire);
    }
    if (!m.ok || !p.ok) { if (error) *error = WorkshopError(@"depot manifest 解析失败"); return nil; }
    result[@"files"] = files;
    return result;
}

+ (NSData *)processChunk:(NSData *)raw key:(NSData *)depotKey expectedLength:(NSUInteger)length checksum:(uint32_t)checksum error:(NSError **)error {
    NSData *data = raw;
    if (depotKey) {
        data = SteamDecrypt(raw, depotKey);
        if (!data) { if (error) *error = WorkshopError(@"分块解密失败"); return nil; }
    }
    const char *b = (const char *)data.bytes;
    NSData *plain = nil;
    if (data.length >= 4 && memcmp(b, "VSZa", 4) == 0) { if (error) *error = WorkshopError(@"该条目使用 Zstandard 压缩分块，iPad 版暂不支持（可在电脑上下载后导入 ZIP）"); return nil; }
    else if (data.length >= 3 && memcmp(b, "VZa", 3) == 0) plain = DecompressVZip(data, error);
    else if (data.length >= 4 && memcmp(b, "PK\x03\x04", 4) == 0) { NSDictionary *entries = STS2ZipReadData(data, error); plain = entries.count == 1 ? entries.allValues.firstObject : nil; if (!plain && error && !*error) *error = WorkshopError(@"分块 ZIP 内容异常"); }
    else if (!depotKey && data.length == length) plain = data;
    else { if (error) *error = WorkshopError(@"不支持的分块压缩格式"); return nil; }
    if (!plain) return nil;
    if (plain.length != length) { if (error) *error = WorkshopError(@"分块长度不符"); return nil; }
    if ([self steamAdler32:plain] != checksum) { if (error) *error = WorkshopError(@"分块校验和不符"); return nil; }
    return plain;
}

#pragma mark Network

- (NSData *)syncGET:(NSURL *)url session:(NSURLSession *)session status:(NSInteger *)status maxBytes:(NSUInteger)maxBytes cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    __block NSData *data = nil; __block NSInteger code = 0; __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; code = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0; failure = e; dispatch_semaphore_signal(done);
    }];
    [task resume];
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)))
        if (cancelled && cancelled()) { [task cancel]; dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER); if (error) *error = WorkshopError(@"已取消下载"); return nil; }
    if (status) *status = code;
    if (failure) { if (error) *error = [NSError errorWithDomain:STS2WorkshopErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"网络请求失败（%@）", url.host], NSUnderlyingErrorKey: failure}]; return nil; }
    if (data.length > maxBytes) { if (error) *error = WorkshopError(@"响应超出大小上限"); return nil; }
    return data ?: [NSData data];
}

- (void)fetch:(NSURLRequest *)request completion:(void (^)(NSData *, NSInteger, NSError *))completion {
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(data, status, error); });
    }] resume];
}

- (void)itemsForIds:(NSArray<NSString *> *)ids completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion { [self detailsForIds:ids completion:completion]; }

- (void)detailsForIds:(NSArray<NSString *> *)ids completion:(void (^)(NSArray *items, NSError *error))completion {
    if (!ids.count) { completion(@[], nil); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSMutableString *body = [NSMutableString stringWithFormat:@"itemcount=%lu", (unsigned long)ids.count];
    [ids enumerateObjectsUsingBlock:^(NSString *identifier, NSUInteger index, BOOL *stop) { [body appendFormat:@"&publishedfileids%%5B%lu%%5D=%@", (unsigned long)index, identifier]; }];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [self fetch:request completion:^(NSData *data, NSInteger status, NSError *error) {
        if (error || status != 200) {
            NSError *failure = WorkshopError(error ? @"连接 Steam API 失败，请检查网络（部分地区需要加速器）。" : [NSString stringWithFormat:@"Steam API 返回 HTTP %ld", (long)status]);
            [STS2Log log:STS2LogLevelWarn tag:STS2LogTagWorkshop message:@"获取工坊详情失败" detail:error ?: failure];
            completion(@[], failure); return;
        }
        NSArray *items = [STS2SteamWorkshop itemsFromDetailsJSON:data];
        NSMutableDictionary *byId = [NSMutableDictionary dictionary];
        for (NSDictionary *item in items) byId[item[@"id"]] = item;
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSString *identifier in ids) if (byId[identifier]) [ordered addObject:byId[identifier]];
        completion(ordered, nil);
    }];
}

- (void)browse:(NSString *)query page:(NSInteger)page sort:(STS2WorkshopSort)sort completion:(void (^)(NSArray<NSDictionary *> *, BOOL, NSError *))completion {
    NSString *sortValue = @[@"trend", @"mostrecent", @"lastupdated", @"totaluniquesubscribers"][MAX(0, MIN(3, sort))];
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://steamcommunity.com/workshop/browse/"];
    NSMutableArray *items = [@[[NSURLQueryItem queryItemWithName:@"appid" value:[NSString stringWithFormat:@"%lu", (unsigned long)STS2WorkshopAppId]],
                               [NSURLQueryItem queryItemWithName:@"searchtext" value:query ?: @""], [NSURLQueryItem queryItemWithName:@"childpublishedfileid" value:@"0"],
                               [NSURLQueryItem queryItemWithName:@"l" value:@"schinese"], [NSURLQueryItem queryItemWithName:@"browsesort" value:sortValue],
                               [NSURLQueryItem queryItemWithName:@"section" value:@"readytouseitems"], [NSURLQueryItem queryItemWithName:@"actualsort" value:sortValue],
                               [NSURLQueryItem queryItemWithName:@"p" value:[NSString stringWithFormat:@"%ld", (long)MAX(1, page)]],
                               [NSURLQueryItem queryItemWithName:@"numperpage" value:@"30"]] mutableCopy];
    if (sort != STS2WorkshopSortRecent) [items addObject:[NSURLQueryItem queryItemWithName:@"days" value:@"-1"]];
    components.queryItems = items;
    STS2LogI(STS2LogTagWorkshop, @"浏览工坊：「%@」第 %ld 页（%@）", query ?: @"", (long)page, sortValue);
    [self fetch:[NSURLRequest requestWithURL:components.URL] completion:^(NSData *data, NSInteger status, NSError *error) {
        if (error || status != 200) {
            NSError *failure = WorkshopError(error ? @"Steam 社区（steamcommunity.com）在当前网络无法访问，工坊列表加载不了。可以开加速器后重试，或用「按链接 / ID 打开」直接打开条目（只需要 Steam API，通常可访问）。" : [NSString stringWithFormat:@"Steam 社区返回 HTTP %ld", (long)status]);
            [STS2Log log:STS2LogLevelWarn tag:STS2LogTagWorkshop message:@"浏览工坊失败" detail:error ?: failure];
            completion(@[], NO, failure); return;
        }
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *ids = [STS2SteamWorkshop itemIdsFromBrowseHTML:html];
        BOOL hasNext = [html containsString:[NSString stringWithFormat:@"p=%ld", (long)MAX(1, page) + 1]];
        [self detailsForIds:ids completion:^(NSArray *details, NSError *detailError) { completion(details, hasNext, detailError); }];
    }];
}

- (void)detailsForItem:(NSDictionary *)item completion:(void (^)(NSDictionary *, NSError *))completion {
    [self detailsForIds:@[item[@"id"]] completion:^(NSArray *items, NSError *error) {
        NSMutableDictionary *detail = [(items.firstObject ?: item) mutableCopy];
        NSURL *page = [NSURL URLWithString:[@"https://steamcommunity.com/sharedfiles/filedetails/?l=schinese&id=" stringByAppendingString:item[@"id"]]];
        [self fetch:[NSURLRequest requestWithURL:page] completion:^(NSData *data, NSInteger status, NSError *pageError) {
            NSString *html = status == 200 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSMutableArray *shots = [[STS2SteamWorkshop screenshotURLsFromPageHTML:html ?: @""] mutableCopy];
            if (![shots containsObject:detail[@"preview"]] && [detail[@"preview"] length]) [shots insertObject:detail[@"preview"] atIndex:0];
            detail[@"screenshots"] = shots;
            NSMutableArray *required = [NSMutableArray array];
            NSRange section = html ? [html rangeOfString:@"requiredItemsContainer"] : NSMakeRange(NSNotFound, 0);
            if (section.location != NSNotFound) {
                NSString *tail = [html substringWithRange:NSMakeRange(section.location, MIN((NSUInteger)6000, html.length - section.location))];
                for (NSString *identifier in [STS2SteamWorkshop itemIdsFromBrowseHTML:tail]) if (![identifier isEqual:item[@"id"]]) [required addObject:identifier];
            }
            detail[@"requiredItems"] = required;
            completion(detail, items.count ? nil : error);
        }];
    }];
}

- (void)imageDataForURL:(NSString *)url completion:(void (^)(NSData *))completion {
    NSData *cached = [self.images objectForKey:url];
    if (cached) { completion(cached); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (![u.scheme.lowercaseString isEqual:@"https"]) { completion(nil); return; }
    [self fetch:[NSURLRequest requestWithURL:u] completion:^(NSData *data, NSInteger status, NSError *error) {
        if (status == 200 && data.length) [self.images setObject:data forKey:url cost:data.length];
        completion(status == 200 ? data : nil);
    }];
}

#pragma mark Download

- (NSURL *)supplyURL:(NSString *)path item:(NSString *)identifier extra:(NSDictionary *)extra {
    NSURLComponents *c = [NSURLComponents componentsWithString:[kSupplyStation stringByAppendingString:path]];
    NSMutableArray *q = [@[[NSURLQueryItem queryItemWithName:@"appId" value:[NSString stringWithFormat:@"%lu", (unsigned long)STS2WorkshopAppId]], [NSURLQueryItem queryItemWithName:@"publishedFileId" value:identifier]] mutableCopy];
    [extra enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [q addObject:[NSURLQueryItem queryItemWithName:k value:v]]; }];
    c.queryItems = q;
    return c.URL;
}

static NSURL *CheckedOrigin(NSString *origin) {
    NSURLComponents *c = [NSURLComponents componentsWithString:origin ?: @""];
    NSString *scheme = c.scheme.lowercaseString;
    if (!c.host.length || c.user || c.password || c.query || c.fragment || !([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) || (c.path.length && ![c.path isEqual:@"/"])) return nil;
    if (c.port && !(([scheme isEqual:@"https"] && c.port.integerValue == 443) || ([scheme isEqual:@"http"] && c.port.integerValue == 80))) return nil;
    // 补给站可能给 http 源；内容与授权一律走 TLS。
    c.scheme = @"https"; c.port = nil; c.path = @"/";
    return c.URL;
}

- (NSDictionary *)descriptorFor:(NSString *)identifier refresh:(BOOL)refresh cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSInteger status = 0;
    NSData *data = [self syncGET:[self supplyURL:@"descriptor" item:identifier extra:refresh ? @{@"refresh": @"true"} : @{}] session:self.noRedirect status:&status maxBytes:kMaxJsonBytes cancelled:cancelled error:error];
    if (!data) return nil;
    if (status != 200) { if (error) *error = WorkshopError(status == 404 ? @"补给站暂时没有这个条目的下载信息（可能已下架或仅限订阅）。" : [NSString stringWithFormat:@"补给站返回 HTTP %ld", (long)status]); return nil; }
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![d isKindOfClass:NSDictionary.class] || [d[@"appId"] unsignedIntegerValue] != STS2WorkshopAppId || ![[d[@"publishedFileId"] description] isEqual:identifier]) {
        if (error) *error = WorkshopError(@"补给站返回的条目不匹配，已停止。"); return nil;
    }
    return d;
}

- (BOOL)downloadItem:(NSDictionary *)item into:(NSURL *)directory progress:(void (^)(double, NSString *))progress cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    NSString *identifier = item[@"id"];
    void (^report)(double, NSString *) = ^(double f, NSString *s) { if (progress) progress(f, s); };
    report(0, @"获取下载授权…");
    STS2LogI(STS2LogTagWorkshop, @"开始下载工坊条目 %@（%@）", identifier, item[@"title"]);
    NSDictionary *descriptor = [self descriptorFor:identifier refresh:NO cancelled:cancelled error:error];
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *(^expires)(NSDictionary *) = ^NSDate *(NSDictionary *d) {
        NSString *text = [d[@"expiresAt"] isKindOfClass:NSString.class] ? d[@"expiresAt"] : @"";
        NSDate *date = [iso dateFromString:text];
        if (!date) { NSISO8601DateFormatter *plain = [NSISO8601DateFormatter new]; date = [plain dateFromString:text]; }
        return date ?: NSDate.distantPast;
    };
    if (descriptor && [expires(descriptor) timeIntervalSinceNow] <= 0) descriptor = [self descriptorFor:identifier refresh:YES cancelled:cancelled error:error];
    if (!descriptor) return NO;
    NSString *mode = descriptor[@"mode"];
    if ([mode isEqual:@"DIRECT"]) {
        NSURL *url = [NSURL URLWithString:descriptor[@"directUrl"] ?: @""];
        if (![url.scheme.lowercaseString isEqual:@"https"] || url.user || url.password) { if (error) *error = WorkshopError(@"补给站给出的直链不安全，已停止。"); return NO; }
        NSString *name = [[descriptor[@"fileName"] description] lastPathComponent];
        if (!name.length || !STS2ZipSafeRelativePath(name)) name = [identifier stringByAppendingString:@".zip"];
        report(0.05, [@"下载 " stringByAppendingString:name]);
        NSInteger status = 0;
        NSData *data = [self syncGET:url session:self.noRedirect status:&status maxBytes:(NSUInteger)MIN(kMaxItemBytes, (unsigned long long)NSUIntegerMax) cancelled:cancelled error:error];
        if (!data) return NO;
        if (status != 200) { if (error) *error = WorkshopError([NSString stringWithFormat:@"直链下载返回 HTTP %ld", (long)status]); return NO; }
        if (![data writeToURL:[directory URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:error]) return NO;
        report(1, @"下载完成");
        return YES;
    }
    if (![mode isEqual:@"UGC"]) { if (error) *error = WorkshopError(@"补给站返回了不支持的下载方式。"); return NO; }
    NSData *key = [[NSData alloc] initWithBase64EncodedString:descriptor[@"depotKeyBase64"] ?: @"" options:0];
    NSString *depotId = [descriptor[@"depotId"] description], *manifestId = [descriptor[@"manifestId"] description], *requestCode = [descriptor[@"requestCode"] description];
    NSMutableArray<NSDictionary *> *endpoints = [NSMutableArray array];
    for (NSDictionary *e in [descriptor[@"endpoints"] isKindOfClass:NSArray.class] ? descriptor[@"endpoints"] : @[]) {
        NSURL *origin = [e isKindOfClass:NSDictionary.class] ? CheckedOrigin(e[@"origin"]) : nil;
        if (origin) [endpoints addObject:@{@"origin": origin, @"query": [e[@"query"] isKindOfClass:NSString.class] ? e[@"query"] : @""}];
    }
    if (key.length != 32 || !depotId.length || !manifestId.length || !requestCode.length || !endpoints.count) { if (error) *error = WorkshopError(@"补给站返回的授权信息不完整。"); return NO; }

    NSMutableDictionary<NSString *, NSString *> *tokens = [NSMutableDictionary dictionary];
    NSObject *tokenLock = [NSObject new];
    // CDN 令牌：先用 endpoint 自带的 query，遇到 401/403 再向补给站要新的。
    NSData *(^fetchCDN)(NSString *, NSUInteger, NSError **) = ^NSData *(NSString *path, NSUInteger offset, NSError **e) {
        NSError *last = nil;
        for (NSUInteger attempt = 0; attempt < endpoints.count * 2; attempt++) {
            NSDictionary *endpoint = endpoints[(offset + attempt) % endpoints.count];
            NSString *host = [endpoint[@"origin"] host];
            for (int refresh = 0; refresh < 2; refresh++) {
                NSString *query;
                @synchronized (tokenLock) { query = tokens[host] ?: endpoint[@"query"]; }
                if (refresh || !query.length) {
                    NSInteger status = 0;
                    NSData *tokenData = [self syncGET:[self supplyURL:@"cdn/token" item:identifier extra:refresh ? @{@"host": host, @"refresh": @"true"} : @{@"host": host}] session:self.noRedirect status:&status maxBytes:kMaxJsonBytes cancelled:cancelled error:&last];
                    NSDictionary *token = status == 200 && tokenData ? [NSJSONSerialization JSONObjectWithData:tokenData options:0 error:nil] : nil;
                    NSURL *tokenOrigin = [token isKindOfClass:NSDictionary.class] ? CheckedOrigin(token[@"origin"]) : nil;
                    NSString *q = [[token[@"query"] description] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"? \n\r"]];
                    if (!tokenOrigin || ![tokenOrigin.host isEqual:host] || !q.length) { last = last ?: WorkshopError(@"补给站 CDN 令牌无效"); break; }
                    @synchronized (tokenLock) { tokens[host] = q; }
                    query = q;
                }
                NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"?"]];
                NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@%@", [endpoint[@"origin"] absoluteString], path, trimmed.length ? @"?" : @"", trimmed]];
                NSInteger status = 0;
                NSData *data = [self syncGET:url session:self.noRedirect status:&status maxBytes:128 * 1024 * 1024 cancelled:cancelled error:&last];
                if (cancelled && cancelled()) { if (e) *e = WorkshopError(@"已取消下载"); return nil; }
                if (data && status == 200) return data;
                if (data && (status == 401 || status == 403) && !refresh) continue;
                if (data) last = WorkshopError([NSString stringWithFormat:@"Steam CDN %@ 返回 HTTP %ld", host, (long)status]);
                break;
            }
        }
        if (e) *e = last ?: WorkshopError(@"Steam CDN 不可用");
        return nil;
    };

    report(0.02, @"下载文件清单…");
    NSData *manifestData = fetchCDN([NSString stringWithFormat:@"depot/%@/manifest/%@/5/%@", depotId, manifestId, requestCode], 0, error);
    if (!manifestData) return NO;
    NSDictionary *manifest = [STS2SteamWorkshop parseManifest:manifestData error:error];
    if (!manifest) return NO;
    BOOL encrypted = [manifest[@"filenamesEncrypted"] boolValue];
    NSMutableArray *files = [NSMutableArray array];
    unsigned long long total = 0;
    NSMutableDictionary<NSData *, NSDictionary *> *uniqueChunks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSData *, NSMutableArray *> *destinations = [NSMutableDictionary dictionary];
    for (NSDictionary *file in manifest[@"files"]) {
        NSString *path = encrypted ? [STS2SteamWorkshop decryptFilename:file[@"path"] key:key] : [file[@"path"] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!path) { if (error) *error = WorkshopError(@"文件名解密失败"); return NO; }
        if ([file[@"linkTarget"] length]) { STS2LogW(STS2LogTagWorkshop, @"跳过符号链接条目 %@", path); continue; }
        if (!STS2ZipSafeRelativePath(path)) { if (error) *error = WorkshopError([@"条目包含不安全的路径：" stringByAppendingString:path]); return NO; }
        NSURL *target = [directory URLByAppendingPathComponent:path];
        if ([file[@"flags"] unsignedIntValue] & 64) { [NSFileManager.defaultManager createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:nil]; continue; }
        total += [file[@"size"] unsignedLongLongValue];
        if (total > kMaxItemBytes) { if (error) *error = WorkshopError(@"条目超过 1 GiB，iPad 上不支持下载。"); return NO; }
        [NSFileManager.defaultManager createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSData data] writeToURL:target options:0 error:error]) return NO;
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:target error:error];
        if (!handle) return NO;
        [handle truncateFileAtOffset:[file[@"size"] unsignedLongLongValue]];
        [files addObject:@{@"path": path, @"url": target, @"handle": handle, @"sha": file[@"sha"], @"size": file[@"size"]}];
        for (NSDictionary *chunk in file[@"chunks"]) {
            uniqueChunks[chunk[@"id"]] = chunk;
            NSMutableArray *list = destinations[chunk[@"id"]] ?: [NSMutableArray array];
            [list addObject:@{@"handle": handle, @"offset": chunk[@"offset"]}];
            destinations[chunk[@"id"]] = list;
        }
    }
    NSArray *chunks = uniqueChunks.allValues;
    __block NSUInteger done = 0;
    __block NSError *failure = nil;
    dispatch_queue_t writer = dispatch_queue_create("com.sts2.workshop.write", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t slots = dispatch_semaphore_create(kChunkConcurrency);
    dispatch_group_t group = dispatch_group_create();
    NSObject *stateLock = [NSObject new];
    for (NSUInteger index = 0; index < chunks.count; index++) {
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        @synchronized (stateLock) { if (failure) { dispatch_semaphore_signal(slots); break; } }
        NSDictionary *chunk = chunks[index];
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableString *hex = [NSMutableString string];
            const uint8_t *idBytes = (const uint8_t *)[chunk[@"id"] bytes];
            for (NSUInteger i = 0; i < [chunk[@"id"] length]; i++) [hex appendFormat:@"%02x", idBytes[i]];
            NSError *chunkError = nil;
            NSData *plain = nil;
            for (int attempt = 0; attempt < 3 && !plain; attempt++) {
                NSData *raw = fetchCDN([NSString stringWithFormat:@"depot/%@/chunk/%@", depotId, hex], index + attempt, &chunkError);
                if (!raw) { if (cancelled && cancelled()) break; continue; }
                plain = [STS2SteamWorkshop processChunk:raw key:key expectedLength:[chunk[@"original"] unsignedIntegerValue] checksum:[chunk[@"crc"] unsignedIntValue] error:&chunkError];
                if (!plain && [chunkError.localizedDescription containsString:@"Zstandard"]) break;
            }
            if (plain) {
                dispatch_sync(writer, ^{
                    for (NSDictionary *d in destinations[chunk[@"id"]]) { NSFileHandle *h = d[@"handle"]; [h seekToFileOffset:[d[@"offset"] unsignedLongLongValue]]; [h writeData:plain]; }
                });
                NSUInteger finished;
                @synchronized (stateLock) { finished = ++done; }
                report(0.05 + 0.9 * finished / MAX((NSUInteger)1, chunks.count), [NSString stringWithFormat:@"下载分块 %lu/%lu", (unsigned long)finished, (unsigned long)chunks.count]);
            } else {
                @synchronized (stateLock) { if (!failure) failure = chunkError ?: WorkshopError(@"分块下载失败"); }
            }
            dispatch_semaphore_signal(slots);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    for (NSDictionary *file in files) [file[@"handle"] closeFile];
    if (failure) { if (error) *error = failure; return NO; }
    report(0.97, @"校验文件…");
    for (NSDictionary *file in files) {
        NSData *data = [NSData dataWithContentsOfURL:file[@"url"] options:NSDataReadingMappedIfSafe error:nil];
        unsigned char digest[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
        if ([file[@"sha"] length] == CC_SHA1_DIGEST_LENGTH && memcmp(digest, [file[@"sha"] bytes], CC_SHA1_DIGEST_LENGTH) != 0)
            STS2LogW(STS2LogTagWorkshop, @"%@ 的 SHA-1 与清单不同，但所有分块 Adler32 校验通过（与 Android 同样继续）", file[@"path"]);
    }
    STS2LogI(STS2LogTagWorkshop, @"工坊条目 %@ 下载完成：%lu 个文件，%lu 个分块", identifier, (unsigned long)files.count, (unsigned long)chunks.count);
    report(1, @"下载完成");
    return YES;
}
@end
