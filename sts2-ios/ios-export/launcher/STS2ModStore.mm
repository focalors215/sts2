#import "STS2ModStore.h"
#import "STS2ZipArchive.h"
#import <CommonCrypto/CommonDigest.h>

static NSError *ModError(NSString *message) { return [NSError errorWithDomain:@"STS2Mods" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL SafePath(NSString *path) {
    if (!path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@":"] || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"]) if (!part.length || [part isEqual:@".."] || [part isEqual:@"."]) return NO;
    return YES;
}
static BOOL ValidSHA(id value) {
    if(![value isKindOfClass:NSString.class]||[value length]!=64)return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location==NSNotFound;
}
static BOOL CodePath(NSString *path) {
    return [@[@"dll", @"cs", @"gd", @"gdc", @"gdextension", @"dylib", @"so", @"exe", @"wasm"] containsObject:path.pathExtension.lowercaseString];
}
static BOOL StaticResourcePath(NSString *path) {
    // Scenes and serialized/import resources can embed or redirect executable code.
    // This deliberately small whitelist cannot admit arbitrary Godot Resources.
    return [@[@"png",@"jpg",@"jpeg",@"webp",@"ogg",@"wav",@"json",@"csv",@"txt"] containsObject:path.pathExtension.lowercaseString];
}
static NSString *Hash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString string]; for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [result appendFormat:@"%02x", digest[i]]; return result;
}
// Strict standalone Godot 4 PCK v2/v3 subset. Unknown/encrypted/removal/sparse flags fail closed.
static BOOL ResourcePCK(NSData *data, BOOL *containsCode = nullptr) {
    const uint8_t *bytes=(const uint8_t *)data.bytes; NSUInteger n=data.length, pos=0; BOOL ok=YES;
    auto u32 = [&]() -> uint32_t { if(pos>n || n-pos<4){ok=NO;return 0;} uint32_t v=0;for(int j=0;j<4;j++)v|=(uint32_t)bytes[pos++]<<(8*j);return v; };
    auto u64 = [&]() -> uint64_t {uint64_t a=u32(),b=u32();return a|(b<<32);};
    if(u32()!=0x43504447) return NO; uint32_t version=u32(),major=u32(),minor=u32();u32();
    if((version!=2&&version!=3)||major!=4||minor>5) return NO;
    uint32_t flags=u32(); uint64_t base=u64(); if(flags&~2U) return NO;
    if(version==3){uint64_t directory=u64();if(directory<40||directory>n)return NO;pos=(NSUInteger)directory;}else{if(n<96)return NO;pos=96;}
    uint32_t count=u32(); if(!count||count>100000) return NO;
    NSMutableSet *names=[NSMutableSet set]; NSMutableArray *ranges=[NSMutableArray array];
    for(uint32_t i=0;ok&&i<count;i++) {
        uint32_t len=u32();if(!ok||!len||len>4096||pos>n||len>n-pos)return NO;
        NSData *raw=[NSData dataWithBytes:bytes+pos length:len];pos+=len;
        // PCK paths use zero padding to four bytes; embedded zero is not a path separator.
        const uint8_t *r=(const uint8_t *)raw.bytes;NSUInteger useful=len;while(useful&&r[useful-1]==0)useful--;
        NSString *name=[[NSString alloc]initWithBytes:r length:useful encoding:NSUTF8StringEncoding];
        if([name hasPrefix:@"res://"])name=[name substringFromIndex:6];
        if(name&&CodePath(name)){if(containsCode)*containsCode=YES;return NO;}
        if(!name||!SafePath(name)||!StaticResourcePath(name)||[names containsObject:name.lowercaseString])return NO;[names addObject:name.lowercaseString];
        uint64_t offset=u64(),size=u64();for(int j=0;j<4;j++)u32();uint32_t entryFlags=u32();
        if(!ok||entryFlags||base>n||offset>n-base||size>n-base-offset)return NO;
        [ranges addObject:@[@(base+offset),@(size)]];
    }
    if(!ok)return NO;
    // Data may precede a v3 directory, but may never overlap its table or the header.
    NSUInteger directoryStart=(version==2?96:0); if(version==3){uint64_t d=0;for(int j=0;j<8;j++)d|=(uint64_t)bytes[32+j]<<(8*j);directoryStart=(NSUInteger)d;}
    for(NSArray *range in ranges){uint64_t start=[range[0] unsignedLongLongValue],size=[range[1] unsignedLongLongValue];if(start<(version==2?96:40)||(start<pos&&start+size>directoryStart))return NO;}
    return YES;
}
@interface STS2ModStore ()
@property NSURL *documentsURL;
@property NSURL *root;
@property NSURL *staging;
@property NSURL *compiledModsURL;
@property BOOL allowInjectedCompiledMods;
@property dispatch_queue_t queue;
@end
@implementation STS2ModStore
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    if((self=[super init])){_documentsURL=documentsURL.URLByStandardizingPath.URLByResolvingSymlinksInPath;_root=[_documentsURL URLByAppendingPathComponent:@"Launcher/Mods" isDirectory:YES];_staging=[_root URLByAppendingPathComponent:@".staging" isDirectory:YES];_compiledModsURL=[[NSBundle mainBundle] URLForResource:@"compiled-mods" withExtension:@"json"];_queue=dispatch_queue_create("sts2.modstore",DISPATCH_QUEUE_SERIAL);}return self;
}
#if defined(STS2_MODSTORE_TESTING)
- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL compiledModsURLForTesting:(NSURL *)compiledModsURL {
    if ((self=[self initWithDocumentsURL:documentsURL])) { _compiledModsURL=compiledModsURL; _allowInjectedCompiledMods=YES; }
    return self;
}
#endif
- (BOOL)prepare:(NSError **)error {return [[NSFileManager defaultManager]createDirectoryAtURL:self.staging withIntermediateDirectories:YES attributes:nil error:error];}
- (NSMutableArray *)readIndex:(NSError **)error {
    NSURL *url=[self.root URLByAppendingPathComponent:@"index.json"]; if(![[NSFileManager defaultManager]fileExistsAtPath:url.path])return [NSMutableArray array];
    NSData *d=[NSData dataWithContentsOfURL:url options:0 error:error];id obj=d?[NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:error]:nil;
    if(![obj isKindOfClass:NSArray.class]){if(error&&!*error)*error=ModError(@"MOD 索引损坏，未覆盖原文件。");return nil;}
    NSMutableSet *ids=[NSMutableSet set];
    NSDictionary *capability=[self compiledCapability];
    NSArray *compiled=capability[@"mods"];
    NSMutableArray *enriched=[NSMutableArray arrayWithCapacity:[obj count]];
    for(id entry in obj){
        BOOL valid=[entry isKindOfClass:NSDictionary.class];
        if(valid)valid=ValidSHA(entry[@"id"])&&![ids containsObject:entry[@"id"]]&&[entry[@"displayName"] isKindOfClass:NSString.class]&&[entry[@"source"] isKindOfClass:NSString.class]&&[entry[@"status"] isKindOfClass:NSString.class]&&[entry[@"size"] isKindOfClass:NSNumber.class]&&[entry[@"packs"] isKindOfClass:NSArray.class]&&[entry[@"enabled"] isKindOfClass:NSNumber.class]&&[entry[@"resourceSafe"] isKindOfClass:NSNumber.class];
        if(valid)for(id pack in entry[@"packs"]){if(![pack isKindOfClass:NSDictionary.class]||![pack[@"path"] isKindOfClass:NSString.class]||!SafePath(pack[@"path"])||!ValidSHA(pack[@"sha256"])){valid=NO;break;}}
        if(!valid){if(error)*error=ModError(@"MOD 索引包含无效记录，未覆盖原文件。");return nil;}
        NSMutableDictionary *computed=[entry mutableCopy];
        NSDictionary *match=nil;
        if([computed[@"files"] isKindOfClass:NSArray.class]) for(id candidate in compiled) {
            if(![candidate isKindOfClass:NSDictionary.class]||![candidate[@"files"] isKindOfClass:NSArray.class])continue;
            if([self fileRecords:computed[@"files"] exactlyMatch:candidate[@"files"]]){match=candidate;break;}
        }
        computed[@"compiledSupported"]=@(match!=nil);
        if(match){computed[@"compiledModId"]=match[@"modId"];computed[@"compiledFeature"]=match[@"feature"];computed[@"compiledBuildId"]=capability[@"buildId"];computed[@"compiledSourceSha256"]=match[@"sourceSha256"];} else {
            [computed removeObjectForKey:@"compiledModId"];[computed removeObjectForKey:@"compiledFeature"];[computed removeObjectForKey:@"compiledBuildId"];[computed removeObjectForKey:@"compiledSourceSha256"];
        }
        [ids addObject:entry[@"id"]];[enriched addObject:computed];
    }
    return enriched;
}
- (NSDictionary *)compiledCapability {
    NSURL *url=self.compiledModsURL;
    if(!url)return @{};
#if !defined(STS2_MODSTORE_TESTING)
    // Never consult Documents or any user-writable path in production.
    if(self.allowInjectedCompiledMods)return @{};
#endif
    NSData *data=[NSData dataWithContentsOfURL:url];id object=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![object isKindOfClass:NSDictionary.class]||[object[@"schemaVersion"] integerValue]!=1||![object[@"buildId"] isKindOfClass:NSString.class]||![object[@"mods"] isKindOfClass:NSArray.class])return @{};
    NSMutableArray *valid=[NSMutableArray array];
    for(id candidate in object[@"mods"]) {
        if(![candidate isKindOfClass:NSDictionary.class])continue;
        if(![candidate[@"modId"] isKindOfClass:NSString.class]||![candidate[@"feature"] isKindOfClass:NSString.class]||![candidate[@"version"] isKindOfClass:NSString.class]||![candidate[@"gameVersion"] isKindOfClass:NSString.class]||!ValidSHA(candidate[@"sourceSha256"])||![candidate[@"files"] isKindOfClass:NSArray.class])continue;
        BOOL validFiles=YES;NSMutableSet *paths=[NSMutableSet set];
        for(id file in candidate[@"files"])if(![file isKindOfClass:NSDictionary.class]||![file[@"path"] isKindOfClass:NSString.class]||!SafePath(file[@"path"])||!ValidSHA(file[@"sha256"])||![file[@"size"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)file[@"size"])==CFBooleanGetTypeID()||[file[@"size"] longLongValue]<0||[paths containsObject:file[@"path"]]){validFiles=NO;break;}else [paths addObject:file[@"path"]];
        if(validFiles&&paths.count)[valid addObject:candidate];
    }
    return @{ @"buildId":object[@"buildId"], @"mods":valid };
}
- (BOOL)fileRecords:(NSArray *)left exactlyMatch:(NSArray *)right {
    if(!left.count||left.count!=right.count)return NO;
    NSMutableDictionary *records=[NSMutableDictionary dictionary];
    for(id file in left){if(![file isKindOfClass:NSDictionary.class]||![file[@"path"] isKindOfClass:NSString.class]||!SafePath(file[@"path"])||!ValidSHA(file[@"sha256"])||![file[@"size"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)file[@"size"])==CFBooleanGetTypeID()||records[file[@"path"]])return NO;records[file[@"path"]]=file;}
    for(id file in right){NSDictionary *local=records[file[@"path"]];if(!local||![local[@"sha256"] isEqual:file[@"sha256"]]||[local[@"size"] unsignedLongLongValue]!=[file[@"size"] unsignedLongLongValue])return NO;}
    return YES;
}
- (BOOL)persist:(NSArray *)mods error:(NSError **)error {
    @synchronized(NSFileManager.defaultManager) {
    NSURL *config=[self.documentsURL URLByAppendingPathComponent:@"Launcher/config.json"];
    NSData *old=[NSData dataWithContentsOfURL:config];id parsed=old?[NSJSONSerialization JSONObjectWithData:old options:NSJSONReadingMutableContainers error:error]:nil;
    if(old&&![parsed isKindOfClass:NSDictionary.class]){if(error&&!*error)*error=ModError(@"启动器配置损坏，未覆盖。");return NO;}
    NSMutableDictionary *root=parsed?:[NSMutableDictionary dictionary];
    id schema=root[@"schemaVersion"];
    if(schema&&(![schema isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)schema)==CFBooleanGetTypeID()||[schema doubleValue]!=1.0)){
        if(error)*error=ModError(@"不支持此启动器配置版本，未覆盖原文件。");return NO;
    }
    root[@"schemaVersion"]=@1;
    NSMutableArray *resources=[NSMutableArray array];
    for(NSDictionary *m in mods)if([m[@"enabled"] boolValue]&&[m[@"resourceSafe"] boolValue])for(NSDictionary *p in m[@"packs"]){
        NSString *relative=[NSString stringWithFormat:@"Launcher/Mods/%@/payload/%@",m[@"id"],p[@"path"]];
        [resources addObject:@{@"id":m[@"id"],@"path":relative,@"sha256":p[@"sha256"]}];
    }
    root[@"resourceMods"]=resources;
    NSMutableArray *compiled=[NSMutableArray array];
    for(NSDictionary *m in mods)if([m[@"enabled"] boolValue]&&[m[@"compiledSupported"] boolValue]){
        [compiled addObject:@{@"id":m[@"id"],@"modId":m[@"compiledModId"],@"feature":m[@"compiledFeature"],@"sourceSha256":m[@"compiledSourceSha256"],@"buildId":m[@"compiledBuildId"]}];
    }
    root[@"compiledMods"]=compiled;
    NSMutableArray *indexRecords=[NSMutableArray array];
    for(NSDictionary *record in mods){NSMutableDictionary *clean=[record mutableCopy];for(NSString *key in @[@"compiledSupported",@"compiledModId",@"compiledFeature",@"compiledBuildId",@"compiledSourceSha256"])[clean removeObjectForKey:key];[indexRecords addObject:clean];}
    NSData *index=[NSJSONSerialization dataWithJSONObject:indexRecords options:NSJSONWritingPrettyPrinted error:error];NSData *cfg=[NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:error];
    if(!index||!cfg)return NO;
    // Config is the activation authority; commit it first. Index failure is reported, never silently ignored.
    return [cfg writeToURL:config options:NSDataWritingAtomic error:error]&&[index writeToURL:[self.root URLByAppendingPathComponent:@"index.json"] options:NSDataWritingAtomic error:error];
    }
}
- (void)loadWithCompletion:(void (^)(NSArray<NSDictionary *> *,NSError *))completion {dispatch_async(self.queue,^{NSError *e=nil;[self prepare:&e];NSArray *a=e?nil:[self readIndex:&e];dispatch_async(dispatch_get_main_queue(),^{completion(a?:@[],e);});});}
- (void)createStagingDirectoryWithCompletion:(void (^)(NSURL *,NSError *))completion {dispatch_async(self.queue,^{NSError *e=nil;NSURL *url=nil;if([self prepare:&e]){url=[self.staging URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];if(![[NSFileManager defaultManager]createDirectoryAtURL:url withIntermediateDirectories:NO attributes:nil error:&e])url=nil;}dispatch_async(dispatch_get_main_queue(),^{completion(url,e);});});}
- (BOOL)isStaged:(NSURL *)url {return url.isFileURL&&[url.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqual:self.staging.URLByStandardizingPath.path]&&[url.URLByResolvingSymlinksInPath.path isEqual:url.URLByStandardizingPath.path];}
- (void)discardStagingDirectoryURL:(NSURL *)url completion:(STS2ModCompletion)completion {
    dispatch_async(self.queue, ^{
        NSError *error=nil;
        if(![self isStaged:url])error=ModError(@"只能清理启动器自己的暂存目录。");
        else if([NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSFileManager.defaultManager removeItemAtURL:url error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{completion(error);});
    });
}
- (BOOL)importStaged:(NSURL *)url source:(NSString *)source error:(NSError **)error {
    if(![self isStaged:url]){if(error)*error=ModError(@"只能导入启动器自己的暂存目录。");return NO;}
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableArray *mods=[self readIndex:error];if(!mods)return NO;
    __block NSError *enumerationError=nil;
    NSDirectoryEnumerator *enumerator=[fm enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *u,NSError *e){enumerationError=e;return NO;}];
    NSMutableArray *files=[NSMutableArray array];uint64_t total=0;
    for(NSURL *file in enumerator){NSDictionary *v=[file resourceValuesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLIsDirectoryKey] error:error];if(!v||[v[NSURLIsSymbolicLinkKey] boolValue]||(![v[NSURLIsRegularFileKey] boolValue]&&![v[NSURLIsDirectoryKey] boolValue])){if(error)*error=ModError(@"不允许链接或特殊文件。");return NO;}if([v[NSURLIsRegularFileKey] boolValue])[files addObject:file];}
    if(enumerationError){if(error)*error=enumerationError;return NO;}
    if(!files.count||files.count>10000){if(error)*error=ModError(@"MOD 为空或文件数超限。");return NO;}
    [files sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [a.path compare:b.path];}];
    NSMutableArray *hashes=[NSMutableArray array],*packs=[NSMutableArray array];BOOL code=NO,safe=YES;NSDictionary *manifest=nil;
    for(NSURL *file in files){NSString *basePath=url.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;NSString *filePath=file.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;if(![filePath hasPrefix:[basePath stringByAppendingString:@"/"]]){if(error)*error=ModError(@"文件越过暂存目录。");return NO;}NSString *path=[filePath substringFromIndex:basePath.length+1];if(!SafePath(path)){if(error)*error=ModError(@"无效文件路径。");return NO;}NSDictionary *attr=[fm attributesOfItemAtPath:file.path error:error];if(!attr)return NO;uint64_t size=[attr fileSize];if(size>512ULL*1024*1024||total>1024ULL*1024*1024-size){if(error)*error=ModError(@"MOD 超出 1 GB 安全导入限制。");return NO;}total+=size;NSData *data=[NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:error];if(!data)return NO;NSString *sha=Hash(data);[hashes addObject:@{@"path":path,@"sha256":sha,@"size":@(size)}];if(CodePath(path))code=YES;else if(!StaticResourcePath(path)&&![path.pathExtension.lowercaseString isEqual:@"pck"])safe=NO;
        if([path.pathExtension.lowercaseString isEqual:@"pck"]){BOOL pckCode=NO;BOOL valid=ResourcePCK(data,&pckCode);code|=pckCode;safe&=valid;[packs addObject:@{@"path":path,@"sha256":sha}];}
        if([@[@"manifest.json",@"mod_manifest.json"] containsObject:file.lastPathComponent.lowercaseString]&&data.length<1024*1024){id m=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if([m isKindOfClass:NSDictionary.class])manifest=m;}
    }
    NSString *identity=Hash([NSJSONSerialization dataWithJSONObject:hashes options:NSJSONWritingSortedKeys error:error]);NSString *modID=identity;
    for(NSDictionary *existing in mods)if([existing[@"id"] isEqual:modID]){if(error)*error=ModError(@"这个 MOD 已安装。");return NO;}
    if([manifest[@"has_dll"] respondsToSelector:@selector(boolValue)]&&[manifest[@"has_dll"] boolValue])code=YES;
    BOOL constraints=NO;
    for(NSString *key in @[@"dependencies",@"Dependencies",@"requiredMods",@"RequiredMods"]){id dependency=manifest[key];if(dependency&&dependency!=NSNull.null&&(![dependency respondsToSelector:@selector(count)]||[dependency count]>0))constraints=YES;}
    for(NSString *key in @[@"game_version",@"gameVersion",@"GameVersion",@"min_game_version",@"minGameVersion",@"minimumGameVersion",@"maxGameVersion"]){if(manifest[key]&&manifest[key]!=NSNull.null)constraints=YES;}
    safe=safe&&!code&&packs.count>0&&!constraints;
    NSString *name=nil;for(NSString *key in @[@"name",@"Name",@"title",@"Title",@"id"]){if([manifest[key] isKindOfClass:NSString.class]&&[manifest[key] length]){name=manifest[key];break;}}
    if(!name)name=[source containsString:@" · "]?[[source componentsSeparatedByString:@" · "] lastObject]:@"导入的 MOD";
    if(name.length>200)name=[name substringToIndex:200];
    NSString *status=code?@"代码 MOD · 需预编译，未启用":(constraints?@"依赖或游戏版本待验证，未启用":(safe?@"资源包已校验 · 未启用":@"资源兼容性待验证，未启用"));
    NSMutableDictionary *record=[@{@"id":modID,@"displayName":name,@"source":source?:@"本地文件",@"size":@(total),@"sha256":identity,@"files":hashes,@"packs":packs,@"resourceSafe":@(safe),@"enabled":@NO,@"status":status} mutableCopy];if(manifest)record[@"manifest"]=manifest;
    NSURL *destination=[self.root URLByAppendingPathComponent:modID isDirectory:YES];if(![fm createDirectoryAtURL:destination withIntermediateDirectories:NO attributes:nil error:error])return NO;
    if(![fm moveItemAtURL:url toURL:[destination URLByAppendingPathComponent:@"payload"] error:error]){[fm removeItemAtURL:destination error:nil];return NO;}
    NSData *metadata=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:error];if(!metadata||![metadata writeToURL:[destination URLByAppendingPathComponent:@"meta.json"] options:NSDataWritingAtomic error:error]){[fm removeItemAtURL:destination error:nil];return NO;}
    [mods addObject:record];if(![self persist:mods error:error]){[fm removeItemAtURL:destination error:nil];return NO;}return YES;
}
- (void)importStagedDirectoryURL:(NSURL *)url source:(NSString *)source completion:(STS2ModCompletion)completion {dispatch_async(self.queue,^{NSError *e=nil;[self importStaged:url source:source error:&e];dispatch_async(dispatch_get_main_queue(),^{completion(e);});});}
- (void)importDocumentURL:(NSURL *)url completion:(STS2ModCompletion)completion {dispatch_async(self.queue,^{NSError *e=nil;BOOL scoped=[url startAccessingSecurityScopedResource];NSURL *stage=nil;
    if([self prepare:&e]){stage=[self.staging URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:&e];}
    NSDictionary *v=[url resourceValuesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] error:&e];NSString *ext=url.pathExtension.lowercaseString;
    if(!e&&(![v[NSURLIsRegularFileKey] boolValue]||[v[NSURLIsSymbolicLinkKey] boolValue]||[v[NSURLFileSizeKey] unsignedLongLongValue]>512ULL*1024*1024||![@[@"zip",@"pck"] containsObject:ext]))e=ModError(@"请选择不含链接的 ZIP 或 PCK 文件（PCK 最大 512 MB；ZIP 解压后总计最大 256 MB）。");
    if(!e){NSData *data=[NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&e];if(data&&[ext isEqual:@"zip"]){NSDictionary *files=STS2ZipReadData(data,&e);for(NSString *p in files){if(!SafePath(p)){e=ModError(@"ZIP 路径无效。");break;}NSURL *out=[stage URLByAppendingPathComponent:p];if(![NSFileManager.defaultManager createDirectoryAtURL:out.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&e]||![files[p] writeToURL:out options:NSDataWritingAtomic error:&e])break;}}else if(data){[data writeToURL:[stage URLByAppendingPathComponent:@"resource.pck"] options:NSDataWritingAtomic error:&e];}}
    if(scoped)[url stopAccessingSecurityScopedResource];if(!e)[self importStaged:stage source:@"本地文件" error:&e];if(stage)[NSFileManager.defaultManager removeItemAtURL:stage error:nil];dispatch_async(dispatch_get_main_queue(),^{completion(e);});});}
- (void)mutate:(NSString *)modID block:(BOOL (^)(NSMutableArray *,NSMutableDictionary *,NSError **))block completion:(STS2ModCompletion)completion {dispatch_async(self.queue,^{NSError *e=nil;NSMutableArray *mods=[self readIndex:&e];NSMutableDictionary *found=nil;for(NSMutableDictionary *m in mods)if([m[@"id"] isEqual:modID]){found=m;break;}if(!e&&!found)e=ModError(@"找不到 MOD。");if(!e&&block(mods,found,&e))[self persist:mods error:&e];dispatch_async(dispatch_get_main_queue(),^{completion(e);});});}
- (void)setEnabled:(BOOL)enabled modID:(NSString *)modID completion:(STS2ModCompletion)completion {[self mutate:modID block:^BOOL(NSMutableArray *mods,NSMutableDictionary *m,NSError **e){BOOL compiled=[m[@"compiledSupported"] boolValue];if(enabled&&!compiled&&![m[@"resourceSafe"] boolValue]){*e=ModError(@"此 MOD 含代码或兼容性待验证，不能在 NativeAOT iOS 中启用。");return NO;}if(enabled&&compiled){for(NSDictionary *f in m[@"files"]){NSURL *file=[self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/payload/%@",modID,f[@"path"]]];NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];NSData *d=[NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];if(!d||[attributes[NSFileSize] unsignedLongLongValue]!=[f[@"size"] unsignedLongLongValue]||![Hash(d) isEqual:f[@"sha256"]]){*e=ModError(@"编译 MOD 文件校验失败，请删除后重新导入。");return NO;}}}if(enabled&&!compiled)for(NSDictionary *p in m[@"packs"]){NSURL *file=[self.root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/payload/%@",modID,p[@"path"]]];NSData *d=[NSData dataWithContentsOfURL:file];if(!d||![Hash(d) isEqual:p[@"sha256"]]||!ResourcePCK(d)){*e=ModError(@"资源包校验失败，请重新导入。");return NO;}}m[@"enabled"]=@(enabled);return YES;} completion:completion];}
- (void)moveModID:(NSString *)modID toIndex:(NSUInteger)index completion:(STS2ModCompletion)completion {[self mutate:modID block:^BOOL(NSMutableArray *mods,NSMutableDictionary *m,NSError **e){[mods removeObject:m];[mods insertObject:m atIndex:MIN(index,mods.count)];return YES;} completion:completion];}
- (void)deleteModID:(NSString *)modID completion:(STS2ModCompletion)completion {[self mutate:modID block:^BOOL(NSMutableArray *mods,NSMutableDictionary *m,NSError **e){[mods removeObject:m];return YES;} completion:^(NSError *e){if(e){completion(e);return;}dispatch_async(self.queue,^{NSError *removeError=nil;[NSFileManager.defaultManager removeItemAtURL:[self.root URLByAppendingPathComponent:modID] error:&removeError];dispatch_async(dispatch_get_main_queue(),^{completion(removeError);});});}];}
@end
