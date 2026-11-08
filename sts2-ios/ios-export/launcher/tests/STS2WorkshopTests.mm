// 创意工坊纯逻辑宿主测试：浏览页/详情 JSON 解析、manifest protobuf、文件名解密、AES + VZip(LZMA)/ZIP 分块处理。
// 不联网；LZMA 数据由 python3 lzma 模块生成（run-workshop-tests.sh 传入）。
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import "../STS2SteamWorkshop.h"
#import "../STS2ZipArchive.h"
#import "../STS2Log.h"

static int failures = 0;
static void Check(bool ok, const char *name) { if (ok) printf("[OK] %s\n", name); else { printf("[FAIL] %s\n", name); failures++; } }

static NSData *Aes(NSData *data, NSData *key, NSData *iv, BOOL ecb, BOOL padding) {
    size_t length = 0; NSMutableData *out = [NSMutableData dataWithLength:data.length + 16];
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, (ecb ? kCCOptionECBMode : 0) | (padding ? kCCOptionPKCS7Padding : 0), key.bytes, key.length, iv.bytes, data.bytes, data.length, out.mutableBytes, out.length, &length);
    out.length = length; return out;
}
// 与 Steam 相同：随机 IV，ECB 加密 IV 作为前 16 字节，后面 CBC + PKCS7。
static NSData *SteamEncrypt(NSData *plain, NSData *key) {
    uint8_t ivBytes[16]; arc4random_buf(ivBytes, 16);
    NSData *iv = [NSData dataWithBytes:ivBytes length:16];
    NSMutableData *out = [Aes(iv, key, nil, YES, NO) mutableCopy];
    [out appendData:Aes(plain, key, iv, NO, YES)];
    return out;
}
static void Varint(NSMutableData *d, uint64_t v) { do { uint8_t b = v & 0x7f; v >>= 7; if (v) b |= 0x80; [d appendBytes:&b length:1]; } while (v); }
static void Key(NSMutableData *d, int field, int wire) { Varint(d, (uint64_t)(field << 3 | wire)); }
static void Bytes(NSMutableData *d, int field, NSData *v) { Key(d, field, 2); Varint(d, v.length); [d appendData:v]; }
static void U32LE(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }

int main(int argc, char **argv) {
    @autoreleasepool {
        [STS2Log setupWithLogsDirectory:[NSURL fileURLWithPath:NSTemporaryDirectory()] installCrashHandlers:NO];
        NSString *html = @"<div class=\"workshopItem\"><a href=\"https://steamcommunity.com/sharedfiles/filedetails/?id=3821353824&searchtext=\" data-publishedfileid=\"3821353824\"></a></div><a href=\"https://steamcommunity.com/sharedfiles/filedetails/?id=111\"></a><div data-publishedfileid=\"222\"></div><div data-publishedfileid=\"3821353824\"></div>";
        NSArray *ids = [STS2SteamWorkshop itemIdsFromBrowseHTML:html];
        Check([ids isEqual:@[@"3821353824", @"222"]], "浏览页取条目 ID（去重、保持顺序）");
        Check([[STS2SteamWorkshop itemIdsFromBrowseHTML:@"<a href=\"/sharedfiles/filedetails/?id=5\">"] isEqual:@[@"5"]], "旧版布局回退匹配链接");
        Check([[STS2SteamWorkshop itemIdFromInput:@" https://steamcommunity.com/sharedfiles/filedetails/?id=3821353824&searchtext= "] isEqual:@"3821353824"] && [[STS2SteamWorkshop itemIdFromInput:@"3821353824"] isEqual:@"3821353824"] && ![STS2SteamWorkshop itemIdFromInput:@"abc"] && [[STS2SteamWorkshop itemIdFromInput:@"steamcommunity.com/workshop/filedetails/?id=12345"] isEqual:@"12345"], "从链接或纯数字取条目 ID");
        NSData *json = [@"{\"response\":{\"publishedfiledetails\":[{\"result\":1,\"publishedfileid\":\"10\",\"consumer_app_id\":2868840,\"title\":\"卡牌美化\",\"file_size\":\"2048\",\"preview_url\":\"https://images.steamusercontent.com/ugc/1/\",\"time_updated\":1762650000,\"lifetime_subscriptions\":42,\"tags\":[{\"tag\":\"Cards\"}]},{\"result\":9,\"publishedfileid\":\"11\"},{\"result\":1,\"publishedfileid\":\"12\",\"consumer_app_id\":646570}]}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *items = [STS2SteamWorkshop itemsFromDetailsJSON:json];
        Check(items.count == 1 && [items[0][@"title"] isEqual:@"卡牌美化"] && [items[0][@"size"] isEqual:@2048] && [items[0][@"tags"] isEqual:@[@"Cards"]] && [items[0][@"subscriptions"] isEqual:@42], "详情 JSON：只收本游戏、result=1 的条目");
        NSArray *shots = [STS2SteamWorkshop screenshotURLsFromPageHTML:@"x 'https://images.steamusercontent.com/ugc/1/ABC/?ima=fit' y \"https://images.steamusercontent.com/ugc/1/ABC/\" z https://steamuserimages-a.akamaihd.net/ugc/2/DEF/"];
        Check(shots.count == 2, "截图链接去重");
        uint8_t abc[] = {'a', 'b', 'c'};
        // Steam 变体：a 从 0 开始。手算 "abc"：a=97,195,294；b=97,292,586 → 0x024A0126
        Check([STS2SteamWorkshop steamAdler32:[NSData dataWithBytes:abc length:3]] == 0x024A0126u, "Steam Adler32 变体（a 从 0 开始）");

        uint8_t keyBytes[32]; for (int i = 0; i < 32; i++) keyBytes[i] = (uint8_t)(i * 7 + 3);
        NSData *key = [NSData dataWithBytes:keyBytes length:32];
        NSString *encryptedName = [SteamEncrypt([@"content\\cards.pck" dataUsingEncoding:NSUTF8StringEncoding], key) base64EncodedStringWithOptions:0];
        Check([[STS2SteamWorkshop decryptFilename:encryptedName key:key] isEqual:@"content/cards.pck"], "文件名解密（ECB IV + CBC）并转正斜杠");

        // 合成 manifest：payload（一个文件两个分块）+ metadata（文件名已加密）+ 结束标记，再包进 ZIP。
        NSMutableData *chunk1 = [NSMutableData data]; Bytes(chunk1, 1, [NSData dataWithBytes:"\x01\x02" length:2]); Key(chunk1, 2, 5); U32LE(chunk1, 0xAABBCCDD); Key(chunk1, 3, 0); Varint(chunk1, 0); Key(chunk1, 4, 0); Varint(chunk1, 100); Key(chunk1, 5, 0); Varint(chunk1, 60);
        NSMutableData *chunk2 = [NSMutableData data]; Bytes(chunk2, 1, [NSData dataWithBytes:"\x03\x04" length:2]); Key(chunk2, 2, 5); U32LE(chunk2, 7); Key(chunk2, 3, 0); Varint(chunk2, 100); Key(chunk2, 4, 0); Varint(chunk2, 50); Key(chunk2, 5, 0); Varint(chunk2, 40);
        NSMutableData *mapping = [NSMutableData data]; Bytes(mapping, 1, [encryptedName dataUsingEncoding:NSUTF8StringEncoding]); Key(mapping, 2, 0); Varint(mapping, 150); Key(mapping, 3, 0); Varint(mapping, 0);
        Bytes(mapping, 5, [NSMutableData dataWithLength:20]); Bytes(mapping, 6, chunk1); Bytes(mapping, 6, chunk2); Key(mapping, 9, 0); Varint(mapping, 1); // 未知字段应跳过
        NSMutableData *payload = [NSMutableData data]; Bytes(payload, 1, mapping);
        NSMutableData *metadata = [NSMutableData data]; Key(metadata, 1, 0); Varint(metadata, 2868840); Key(metadata, 2, 0); Varint(metadata, 9876543210ULL); Key(metadata, 4, 0); Varint(metadata, 1);
        NSMutableData *manifest = [NSMutableData data];
        U32LE(manifest, 0x71F617D0); U32LE(manifest, (uint32_t)payload.length); [manifest appendData:payload];
        U32LE(manifest, 0x1F4812BE); U32LE(manifest, (uint32_t)metadata.length); [manifest appendData:metadata];
        U32LE(manifest, 0x1B81B817); U32LE(manifest, 3); [manifest appendBytes:"sig" length:3];
        U32LE(manifest, 0x32C415AB);
        NSError *error = nil;
        NSData *zipped = STS2ZipCreateData(@{@"z": manifest}, &error);
        NSDictionary *parsed = [STS2SteamWorkshop parseManifest:zipped error:&error];
        NSDictionary *file = [parsed[@"files"] firstObject];
        Check([parsed[@"depotId"] isEqual:@2868840] && [parsed[@"manifestId"] isEqual:@9876543210ULL] && [parsed[@"filenamesEncrypted"] boolValue], "manifest 元数据");
        Check([file[@"size"] isEqual:@150] && [file[@"chunks"] count] == 2 && [[file[@"chunks"][0] objectForKey:@"crc"] isEqual:@0xAABBCCDD] && [[file[@"chunks"][1] objectForKey:@"offset"] isEqual:@100], "manifest 文件与分块（含 fixed32、未知字段跳过）");
        Check([[STS2SteamWorkshop decryptFilename:file[@"path"] key:key] isEqual:@"content/cards.pck"], "manifest 内加密文件名可解");
        NSMutableData *broken = [manifest mutableCopy]; broken.length = 20;
        Check(![STS2SteamWorkshop parseManifest:broken error:&error], "截断的 manifest 报错");

        // 分块：ZIP 形式与 VZip(LZMA) 形式，都先 Steam 加密。
        NSData *plain = [[@"" stringByPaddingToLength:4000 withString:@"slay the spire 2 " startingAtIndex:0] dataUsingEncoding:NSUTF8StringEncoding];
        uint32_t crc = [STS2SteamWorkshop steamAdler32:plain];
        NSData *zipChunk = SteamEncrypt(STS2ZipCreateData(@{@"0": plain}, &error), key);
        Check([[STS2SteamWorkshop processChunk:zipChunk key:key expectedLength:plain.length checksum:crc error:&error] isEqual:plain], "加密 ZIP 分块解密解压并校验");
        error = nil;
        Check(![STS2SteamWorkshop processChunk:zipChunk key:key expectedLength:plain.length checksum:crc ^ 1 error:&error] && [error.localizedDescription containsString:@"校验"], "Adler32 不符报错");
        if (argc > 1) {
            NSData *alone = [NSData dataWithContentsOfFile:@(argv[1])]; // python lzma FORMAT_ALONE，内容是 plain
            NSMutableData *vz = [NSMutableData dataWithBytes:"VZa" length:3];
            U32LE(vz, 0); [vz appendData:[alone subdataWithRange:NSMakeRange(0, 5)]];
            [vz appendData:[alone subdataWithRange:NSMakeRange(13, alone.length - 13)]];
            U32LE(vz, 0); U32LE(vz, (uint32_t)plain.length); [vz appendBytes:"zv" length:2];
            error = nil;
            NSData *out = [STS2SteamWorkshop processChunk:SteamEncrypt(vz, key) key:key expectedLength:plain.length checksum:crc error:&error];
            if (!out) printf("vzip error: %s\n", error.localizedDescription.UTF8String);
            Check([out isEqual:plain], "加密 VZip（LZMA）分块经系统 liblzma 解压");
        }
        NSMutableData *zstd = [NSMutableData dataWithBytes:"VSZa" length:4]; [zstd increaseLengthBy:30];
        error = nil;
        Check(![STS2SteamWorkshop processChunk:SteamEncrypt(zstd, key) key:key expectedLength:10 checksum:0 error:&error] && [error.localizedDescription containsString:@"Zstandard"], "Zstd 分块给出明确的不支持提示");
        printf(failures ? "%d FAILED\n" : "ALL PASSED\n", failures);
        return failures ? 1 : 0;
    }
}
