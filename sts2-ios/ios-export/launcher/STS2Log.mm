#import "STS2Log.h"
#include <execinfo.h>
#include <initializer_list>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const STS2LogTagApp = @"app", *const STS2LogTagLaunch = @"launch", *const STS2LogTagOnline = @"online",
    *const STS2LogTagFrp = @"frp", *const STS2LogTagMods = @"mods", *const STS2LogTagSaves = @"saves",
    *const STS2LogTagCloud = @"cloud", *const STS2LogTagWorkshop = @"workshop", *const STS2LogTagNexus = @"nexus",
    *const STS2LogTagUpdate = @"update", *const STS2LogTagUI = @"ui";

static const NSInteger kKeptFiles = 5; // launcher.log + launcher.1.log … launcher.4.log
static NSURL *gDirectory;
static STS2LogLevel gMinimumLevel = STS2LogLevelInfo;
static unsigned long long gMaxBytes = 2ull * 1024 * 1024;
static NSMutableSet<NSString *> *gSecrets;
static NSObject *gLock;
// The signal handler can only use async-signal-safe calls; the path is prepared up front.
static char gCrashPath[1024];
static struct sigaction gPreviousActions[32];
static NSUncaughtExceptionHandler *gPreviousExceptionHandler;
static BOOL gHandlersInstalled;

static NSArray<NSRegularExpression *> *RedactionPatterns(void) {
    static NSArray *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns = @[
            [NSRegularExpression regularExpressionWithPattern:@"(Bearer\\s+)[^\\s\",}]+" options:NSRegularExpressionCaseInsensitive error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(\"?(?:auth\\.)?(?:token|password|passwd|pwd|api[_-]?key|apikey|secret|refresh_?token|access_?token|authorization)\"?\\s*[:=]\\s*\"?)([^\"\\s,}&]+)" options:NSRegularExpressionCaseInsensitive error:nil],
        ];
    });
    return patterns;
}

static void WriteCrashRecord(const char *text) {
    if (!gCrashPath[0]) return;
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    write(fd, text, strlen(text));
    close(fd);
}

static void SignalHandler(int signal, siginfo_t *info, void *context) {
    if (gCrashPath[0]) {
        int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) {
            const char *name = signal == SIGSEGV ? "SIGSEGV" : signal == SIGBUS ? "SIGBUS" : signal == SIGABRT ? "SIGABRT" : signal == SIGILL ? "SIGILL" : signal == SIGFPE ? "SIGFPE" : signal == SIGTRAP ? "SIGTRAP" : "SIGNAL";
            const char *prefix = "致命信号 ";
            write(fd, prefix, strlen(prefix));
            write(fd, name, strlen(name));
            write(fd, "\n", 1);
            void *frames[64];
            int count = backtrace(frames, 64);
            backtrace_symbols_fd(frames, count, fd);
            close(fd);
        }
    }
    // Chain to whatever was installed before us (.NET / Godot), else the default action.
    struct sigaction *previous = &gPreviousActions[signal];
    if (previous->sa_flags & SA_SIGINFO) {
        if (previous->sa_sigaction) { previous->sa_sigaction(signal, info, context); return; }
    } else if (previous->sa_handler != SIG_DFL && previous->sa_handler != SIG_IGN) {
        previous->sa_handler(signal); return;
    }
    sigaction(signal, previous, NULL);
    raise(signal);
}

static void STS2UncaughtExceptionHandler(NSException *exception) {
    [STS2Log log:STS2LogLevelError tag:STS2LogTagApp message:@"未捕获的 Objective-C 异常，应用即将退出" detail:exception];
    NSString *record = [NSString stringWithFormat:@"未捕获异常 %@: %@\n%@\n", exception.name, [STS2Log redact:exception.reason ?: @""], [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    WriteCrashRecord(record.UTF8String);
    if (gPreviousExceptionHandler) gPreviousExceptionHandler(exception);
}

@implementation STS2Log

+ (void)initialize {
    if (self == STS2Log.class) { gLock = [NSObject new]; gSecrets = [NSMutableSet set]; }
}

+ (void)setupWithDocumentsURL:(NSURL *)documentsURL {
    NSURL *directory = [[documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES] URLByAppendingPathComponent:@"logs" isDirectory:YES];
    [self setupWithLogsDirectory:directory installCrashHandlers:YES];
}

+ (void)setupWithLogsDirectory:(NSURL *)directory installCrashHandlers:(BOOL)install {
    @synchronized (gLock) {
        gDirectory = directory;
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *crash = [directory URLByAppendingPathComponent:@"pending-crash.txt"].path;
        strlcpy(gCrashPath, crash.fileSystemRepresentation, sizeof(gCrashPath));
    }
    if (!install || gHandlersInstalled) return;
    gHandlersInstalled = YES;
    gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&STS2UncaughtExceptionHandler);
    // An alternate stack lets the handler run after a stack overflow.
    static char alternate[64 * 1024];
    stack_t stack = {.ss_sp = alternate, .ss_size = sizeof(alternate), .ss_flags = 0};
    sigaltstack(&stack, NULL);
    for (int signal : {SIGABRT, SIGILL, SIGBUS, SIGFPE, SIGSEGV, SIGTRAP}) {
        struct sigaction action = {};
        action.sa_sigaction = SignalHandler;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        sigaction(signal, &action, &gPreviousActions[signal]);
    }
}

+ (NSURL *)logsDirectory { @synchronized (gLock) { return gDirectory; } }
+ (NSURL *)launcherLogURL { return [self.logsDirectory URLByAppendingPathComponent:@"launcher.log"]; }
+ (STS2LogLevel)minimumLevel { return gMinimumLevel; }
+ (void)setMinimumLevel:(STS2LogLevel)level { gMinimumLevel = level; }
+ (unsigned long long)maxFileBytes { return gMaxBytes; }
+ (void)setMaxFileBytes:(unsigned long long)bytes { gMaxBytes = MAX(bytes, 1024ull); }

+ (void)registerSecret:(NSString *)secret {
    NSString *trimmed = [secret stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Very short values would blank out ordinary words; they are still covered by key=value rules.
    if (trimmed.length < 4) return;
    @synchronized (gLock) { [gSecrets addObject:trimmed]; }
}

+ (NSString *)redact:(NSString *)text {
    if (!text.length) return text ?: @"";
    NSMutableString *result = [text mutableCopy];
    NSArray<NSString *> *secrets;
    @synchronized (gLock) { secrets = gSecrets.allObjects; }
    for (NSString *secret in secrets) [result replaceOccurrencesOfString:secret withString:@"***" options:0 range:NSMakeRange(0, result.length)];
    for (NSRegularExpression *pattern in RedactionPatterns())
        [pattern replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"$1***"];
    return result;
}

+ (unichar)letterForLevel:(STS2LogLevel)level {
    switch (level) { case STS2LogLevelDebug: return 'D'; case STS2LogLevelInfo: return 'I'; case STS2LogLevelWarn: return 'W'; default: return 'E'; }
}

+ (NSString *)describeDetail:(id)detail {
    if (!detail) return nil;
    NSMutableString *out = [NSMutableString string];
    if ([detail isKindOfClass:NSException.class]) {
        NSException *e = detail;
        [out appendFormat:@" | %@: %@", e.name, e.reason ?: @""];
        for (NSString *frame in e.callStackSymbols) [out appendFormat:@"\n    at %@", frame];
    } else if ([detail isKindOfClass:NSError.class]) {
        NSError *e = detail;
        [out appendFormat:@" | %@(%ld): %@", e.domain, (long)e.code, e.localizedDescription];
        NSError *underlying = e.userInfo[NSUnderlyingErrorKey];
        for (int depth = 0; [underlying isKindOfClass:NSError.class] && depth < 5; depth++) {
            [out appendFormat:@"\n    caused by %@(%ld): %@", underlying.domain, (long)underlying.code, underlying.localizedDescription];
            underlying = underlying.userInfo[NSUnderlyingErrorKey];
        }
    } else {
        [out appendFormat:@" | %@", [detail description]];
    }
    return out;
}

+ (NSString *)formatLineWithDate:(NSDate *)date timeZone:(NSTimeZone *)zone level:(STS2LogLevel)level tag:(NSString *)tag
                         message:(NSString *)message detail:(id)detail {
    static NSMutableDictionary<NSString *, NSDateFormatter *> *formatters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ formatters = [NSMutableDictionary dictionary]; });
    NSDateFormatter *formatter;
    @synchronized (formatters) {
        formatter = formatters[zone.name];
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierISO8601];
            formatter.timeZone = zone;
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx";
            formatters[zone.name] = formatter;
        }
    }
    NSString *body = [message ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@"\n    "];
    NSString *line = [NSString stringWithFormat:@"%@ %C [%@] %@%@", [formatter stringFromDate:date], [self letterForLevel:level], tag, body, [self describeDetail:detail] ?: @""];
    return [self redact:line];
}

+ (void)log:(STS2LogLevel)level tag:(NSString *)tag message:(NSString *)message { [self log:level tag:tag message:message detail:nil]; }

+ (void)log:(STS2LogLevel)level tag:(NSString *)tag message:(NSString *)message detail:(id)detail {
    if (level < gMinimumLevel) return;
    NSString *line = [self formatLineWithDate:NSDate.date timeZone:NSTimeZone.localTimeZone level:level tag:tag message:message detail:detail];
#if DEBUG
    NSLog(@"%@", line);
#endif
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized (gLock) {
        if (!gDirectory) return;
        NSURL *url = [gDirectory URLByAppendingPathComponent:@"launcher.log"];
        int fd = open(url.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        write(fd, data.bytes, data.length);
        struct stat info;
        BOOL rotate = fstat(fd, &info) == 0 && (unsigned long long)info.st_size > gMaxBytes;
        close(fd);
        if (rotate) [self rotateLocked];
    }
}

+ (void)rotateLocked {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *(^name)(NSInteger) = ^NSURL *(NSInteger index) {
        return [gDirectory URLByAppendingPathComponent:index == 0 ? @"launcher.log" : [NSString stringWithFormat:@"launcher.%ld.log", (long)index]];
    };
    [files removeItemAtURL:name(kKeptFiles - 1) error:nil];
    for (NSInteger index = kKeptFiles - 2; index >= 0; index--) [files moveItemAtURL:name(index) toURL:name(index + 1) error:nil];
}

+ (NSString *)takePreviousCrashReport {
    NSURL *url;
    @synchronized (gLock) { if (!gCrashPath[0]) return nil; url = [NSURL fileURLWithPath:@(gCrashPath)]; }
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    if (!text.length) return nil;
    text = [self redact:text];
    [self log:STS2LogLevelError tag:STS2LogTagApp message:[@"上次运行发生崩溃（下一次启动时补记）：\n" stringByAppendingString:[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]];
    return text;
}
@end

static NSURL *gMarkerURL;

@implementation STS2LaunchMarker
+ (void)setDocumentsURL:(NSURL *)documentsURL {
    @synchronized (self) { gMarkerURL = [[documentsURL URLByAppendingPathComponent:@"Launcher" isDirectory:YES] URLByAppendingPathComponent:@"launch-marker.json"]; }
}
+ (NSURL *)url { @synchronized (self) { return gMarkerURL; } }
+ (void)write:(NSDictionary *)marker {
    NSURL *url = self.url;
    if (!url) return;
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:marker options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error])
        [STS2Log log:STS2LogLevelWarn tag:STS2LogTagLaunch message:@"写入启动标记失败" detail:error];
}
+ (void)writeWithInfo:(NSDictionary *)info {
    NSMutableDictionary *marker = [info mutableCopy];
    marker[@"state"] = @"running";
    marker[@"started"] = @((long long)NSDate.date.timeIntervalSince1970);
    [self write:marker];
}
+ (void)updateState:(NSString *)state {
    NSURL *url = self.url;
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSDictionary *marker = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![marker isKindOfClass:NSDictionary.class]) return;
    NSMutableDictionary *updated = [marker mutableCopy];
    updated[@"state"] = state;
    updated[@"updated"] = @((long long)NSDate.date.timeIntervalSince1970);
    [self write:updated];
}
+ (void)clear { NSURL *url = self.url; if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil]; }
+ (NSDictionary *)takePrevious {
    NSURL *url = self.url;
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) return nil;
    [self clear];
    NSDictionary *marker = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [marker isKindOfClass:NSDictionary.class] ? marker : @{@"state": @"running", @"corrupt": @YES};
}
@end
