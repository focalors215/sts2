#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Small ZIP subset for save/mod bundles. Writes STORE archives; reads STORE and deflate.
/// Rejects unsafe paths, duplicates, encryption, links, multi-disk, ZIP64, and oversized entries.
FOUNDATION_EXPORT NSDictionary<NSString *, NSData *> * _Nullable STS2ZipReadData(NSData *zip, NSError **error);
FOUNDATION_EXPORT NSData * _Nullable STS2ZipCreateData(NSDictionary<NSString *, NSData *> *files, NSError **error);

/// Shared relative-path rule: no absolute, backslash, colon, NUL, empty, "." or ".." components.
FOUNDATION_EXPORT BOOL STS2ZipSafeRelativePath(NSString *path);

NS_ASSUME_NONNULL_END
