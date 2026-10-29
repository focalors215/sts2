#import "STS2ZipArchive.h"
#include <stdint.h>
#include <string.h>
#import <zlib.h>
static const uint32_t kMaxEntries = 4096;
static const uint64_t kMaxTotal = 256ull * 1024 * 1024;
static const uint64_t kMaxItem = 64ull * 1024 * 1024;
static NSError *ArchiveError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"STS2ZipArchive"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}
static uint16_t U16(const uint8_t *p) { return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t U32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void Put16(uint8_t *p, uint16_t x) {
    p[0] = x & 255;
    p[1] = (x >> 8) & 255;
}
static void Put32(uint8_t *p, uint32_t x) {
    p[0] = x & 255;
    p[1] = (x >> 8) & 255;
    p[2] = (x >> 16) & 255;
    p[3] = (x >> 24) & 255;
}
BOOL STS2ZipSafeRelativePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@"\0"] ||
        [path containsString:@":"])
        return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."])
            return NO;
    return YES;
}
@interface STS2ZipEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSData *data;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t localOffset;
@end
@implementation STS2ZipEntry
@end

NSData *STS2ZipCreateData(NSDictionary<NSString *, NSData *> *files, NSError **error) {
    if (files.count > kMaxEntries) {
        if (error)
            *error = ArchiveError(1, @"压缩包文件数量超出限制。");
        return nil;
    }
    NSMutableData *out = [NSMutableData data];
    NSMutableArray<STS2ZipEntry *> *entries = [NSMutableArray array];
    uint64_t total = 0;
    uint64_t encodedSize = 22;
    NSMutableSet *folded = [NSMutableSet set];
    for (NSString *path in [[files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = files[path];
        NSData *name = [path dataUsingEncoding:NSUTF8StringEncoding];
        NSString *fold = [path.lowercaseString precomposedStringWithCanonicalMapping];
        if (!STS2ZipSafeRelativePath(path) || [folded containsObject:fold] || name.length > UINT16_MAX ||
            data.length > kMaxItem || total + data.length > kMaxTotal || out.length > UINT32_MAX) {
            if (error)
                *error = ArchiveError(1, @"存档路径或文件大小超出支持范围。");
            return nil;
        }
        encodedSize += 76ull + 2ull * name.length + data.length;
        if (encodedSize > kMaxTotal + 32ull * 1024 * 1024) {
            if (error)
                *error = ArchiveError(1, @"ZIP encoded size exceeds the reader limit.");
            return nil;
        }
        total += data.length;
        [folded addObject:fold];
    }
    // Validate the full collection before allocating the output archive.
    for (NSString *path in [[files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *data = files[path];
        NSData *name = [path dataUsingEncoding:NSUTF8StringEncoding];
        STS2ZipEntry *e = [STS2ZipEntry new];
        e.path = path;
        e.data = data;
        e.crc = (uint32_t)crc32(0, (const Bytef *)data.bytes, (uInt)data.length);
        e.localOffset = (uint32_t)out.length;
        uint8_t h[30] = {0};
        Put32(h, 0x04034b50);
        Put16(h + 4, 20);
        Put16(h + 6, 0x0800);
        Put16(h + 8, 0);
        Put32(h + 14, e.crc);
        Put32(h + 18, (uint32_t)data.length);
        Put32(h + 22, (uint32_t)data.length);
        Put16(h + 26, (uint16_t)name.length);
        [out appendBytes:h length:30];
        [out appendData:name];
        [out appendData:data];
        [entries addObject:e];
    }
    if (entries.count > UINT16_MAX || out.length > UINT32_MAX) {
        if (error)
            *error = ArchiveError(1, @"压缩包超出支持的 ZIP 格式大小。");
        return nil;
    }
    uint32_t cdOffset = (uint32_t)out.length;
    for (STS2ZipEntry *e in entries) {
        NSData *name = [e.path dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t h[46] = {0};
        Put32(h, 0x02014b50);
        Put16(h + 4, 20);
        Put16(h + 6, 20);
        Put16(h + 8, 0x0800);
        Put16(h + 10, 0);
        Put32(h + 16, e.crc);
        Put32(h + 20, (uint32_t)e.data.length);
        Put32(h + 24, (uint32_t)e.data.length);
        Put16(h + 28, (uint16_t)name.length);
        Put32(h + 42, e.localOffset);
        [out appendBytes:h length:46];
        [out appendData:name];
    }
    uint32_t cdSize = (uint32_t)out.length - cdOffset;
    uint8_t end[22] = {0};
    Put32(end, 0x06054b50);
    Put16(end + 8, (uint16_t)entries.count);
    Put16(end + 10, (uint16_t)entries.count);
    Put32(end + 12, cdSize);
    Put32(end + 16, cdOffset);
    [out appendBytes:end length:22];
    return out;
}

NSDictionary<NSString *, NSData *> *STS2ZipReadData(NSData *zip, NSError **error) {
    const uint8_t *b = (const uint8_t *)zip.bytes;
    NSUInteger n = zip.length;
    if (n < 22) {
        if (error)
            *error = ArchiveError(2, @"ZIP 文件已截断。");
        return nil;
    }
    NSUInteger eocd = NSNotFound, lower = n > 65557 ? n - 65557 : 0;
    for (NSUInteger i = n - 22;; i--) {
        if (U32(b + i) == 0x06054b50) {
            eocd = i;
            break;
        }
        if (i == lower)
            break;
    }
    if (eocd == NSNotFound || eocd + 22 > n || eocd + 22 + U16(b + eocd + 20) != n ||
        U16(b + eocd + 4) != 0 || U16(b + eocd + 6) != 0) {
        if (error)
            *error = ArchiveError(2, @"ZIP 中央目录缺失或压缩包使用了不支持的分卷格式。");
        return nil;
    }
    if (n > kMaxTotal + 32ull * 1024 * 1024) {
        if (error)
            *error = ArchiveError(2, @"ZIP 文件超过大小限制（解压后总计最大 256 MB）。");
        return nil;
    }
    uint16_t count = U16(b + eocd + 10);
    uint32_t cdSize = U32(b + eocd + 12), cdOff = U32(b + eocd + 16);
    if (count == 0xffff || cdSize == 0xffffffff || cdOff == 0xffffffff || count > kMaxEntries ||
        U16(b + eocd + 8) != count || (uint64_t)cdOff + cdSize > eocd) {
        if (error)
            *error = ArchiveError(2, @"ZIP64 或无效中央目录不受支持。");
        return nil;
    }
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSMutableSet *folded = [NSMutableSet set];
    uint64_t total = 0;
    NSUInteger p = cdOff;
    for (uint16_t i = 0; i < count; i++) {
        if (p + 46 > (NSUInteger)cdOff + cdSize || U32(b + p) != 0x02014b50) {
            if (error)
                *error = ArchiveError(2, @"ZIP 中央目录已截断或格式错误。");
            return nil;
        }
        uint16_t flags = U16(b + p + 8), method = U16(b + p + 10), nl = U16(b + p + 28), xl = U16(b + p + 30),
                 cl = U16(b + p + 32);
        uint32_t crc = U32(b + p + 16), csize = U32(b + p + 20), usize = U32(b + p + 24),
                 off = U32(b + p + 42);
        uint32_t attrs = U32(b + p + 38);
        if ((uint64_t)p + 46 + nl + xl + cl > (uint64_t)cdOff + cdSize || U16(b + p + 34) != 0 ||
            (flags & 1) || (flags & ~0x080e) || (method != 0 && method != 8) || csize == 0xffffffff ||
            usize == 0xffffffff || usize > kMaxItem || (uint64_t)total + usize > kMaxTotal) {
            if (error)
                *error = ArchiveError(2, @"ZIP 使用了加密、不支持的压缩方式，或超过大小限制。");
            return nil;
        }
        if ((attrs >> 16 & 0170000) == 0120000) {
            if (error)
                *error = ArchiveError(2, @"ZIP 不允许包含符号链接。");
            return nil;
        }
        NSData *nd = [NSData dataWithBytes:b + p + 46 length:nl];
        if (memchr(nd.bytes, 0, nd.length)) {
            if (error)
                *error = ArchiveError(2, @"ZIP 路径包含空字符。");
            return nil;
        }
        NSString *path = [[NSString alloc] initWithData:nd encoding:NSUTF8StringEncoding];
        BOOL isDir = [path hasSuffix:@"/"];
        NSString *checkPath = isDir ? [path substringToIndex:path.length - 1] : path;
        if (!path || !STS2ZipSafeRelativePath(checkPath)) {
            if (error)
                *error = ArchiveError(2, @"ZIP 包含不安全或无效路径。");
            return nil;
        }
        NSString *fold = [checkPath.lowercaseString precomposedStringWithCanonicalMapping];
        if ([folded containsObject:fold]) {
            if (error)
                *error = ArchiveError(2, @"ZIP 包含忽略大小写后重复的路径。");
            return nil;
        }
        [folded addObject:fold];
        if ((uint64_t)off + 30 > cdOff || U32(b + off) != 0x04034b50) {
            if (error)
                *error = ArchiveError(2, @"ZIP 本地文件记录无效。");
            return nil;
        }
        uint16_t lflags = U16(b + off + 6), lm = U16(b + off + 8);
        uint16_t lnl = U16(b + off + 26), lxl = U16(b + off + 28);
        uint32_t localCRC = U32(b + off + 14), localCompressed = U32(b + off + 18),
                 localSize = U32(b + off + 22);
        BOOL descriptor = (flags & 8) != 0;
        BOOL localMatches =
            descriptor ? ((!localCRC || localCRC == crc) && (!localCompressed || localCompressed == csize) &&
                          (!localSize || localSize == usize))
                       : (localCRC == crc && localCompressed == csize && localSize == usize);
        uint64_t payloadEnd = (uint64_t)off + 30 + lnl + lxl + csize;
        if (lflags != flags || lm != method || !localMatches || payloadEnd > cdOff) {
            if (error)
                *error = ArchiveError(2, @"ZIP 本地文件记录与中央目录不一致。");
            return nil;
        }
        if (descriptor) {
            // Java ZipOutputStream writes authoritative sizes and CRC in the central
            // directory and a trailing 12-byte or signature-prefixed 16-byte descriptor.
            BOOL plain = payloadEnd + 12 <= cdOff && U32(b + payloadEnd) == crc &&
                         U32(b + payloadEnd + 4) == csize && U32(b + payloadEnd + 8) == usize;
            BOOL signedDescriptor = payloadEnd + 16 <= cdOff && U32(b + payloadEnd) == 0x08074b50 &&
                                    U32(b + payloadEnd + 4) == crc && U32(b + payloadEnd + 8) == csize &&
                                    U32(b + payloadEnd + 12) == usize;
            if (!plain && !signedDescriptor) {
                if (error)
                    *error = ArchiveError(2, @"ZIP 数据描述符缺失或与中央目录不一致。");
                return nil;
            }
        }
        if (lnl != nl || memcmp(b + off + 30, b + p + 46, nl) != 0) {
            if (error)
                *error = ArchiveError(2, @"ZIP 本地文件名与中央目录不一致。");
            return nil;
        }
        NSData *comp = [NSData dataWithBytes:b + off + 30 + lnl + lxl length:csize];
        NSMutableData *raw = [NSMutableData dataWithLength:MAX((NSUInteger)usize, (NSUInteger)1)];
        if (method == 0) {
            if (csize != usize) {
                if (error)
                    *error = ArchiveError(2, @"ZIP 存储项的长度不一致。");
                return nil;
            }
            [raw replaceBytesInRange:NSMakeRange(0, usize) withBytes:comp.bytes];
        } else {
            z_stream z;
            memset(&z, 0, sizeof(z));
            z.next_in = (Bytef *)comp.bytes;
            z.avail_in = (uInt)comp.length;
            z.next_out = (Bytef *)raw.mutableBytes;
            z.avail_out = (uInt)(usize ? usize : 1);
            if (inflateInit2(&z, -MAX_WBITS) != Z_OK) {
                if (error)
                    *error = ArchiveError(2, @"无法初始化 ZIP 解压。");
                return nil;
            }
            int zr = inflate(&z, Z_FINISH);
            BOOL good = zr == Z_STREAM_END && z.total_out == usize && z.total_in == csize;
            inflateEnd(&z);
            if (!good) {
                if (error)
                    *error = ArchiveError(2, @"ZIP 压缩数据已截断或无效。");
                return nil;
            }
        }
        [raw setLength:usize];
        if ((uint32_t)crc32(0, (const Bytef *)raw.bytes, (uInt)raw.length) != crc) {
            if (error)
                *error = ArchiveError(2, @"ZIP 校验和验证失败。");
            return nil;
        }
        if (isDir && usize != 0) {
            if (error)
                *error = ArchiveError(2, @"ZIP directory has file content.");
            return nil;
        }
        if (!isDir)
            files[path] = raw;
        total += usize;
        p += 46 + nl + xl + cl;
    }
    if (p != (NSUInteger)cdOff + cdSize) {
        if (error)
            *error = ArchiveError(2, @"ZIP 中央目录长度不一致。");
        return nil;
    }
    return files;
}
