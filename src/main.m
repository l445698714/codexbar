#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <math.h>

typedef NS_ENUM(NSInteger, CBLogLevel) {
    CBLogLevelError = 0,
    CBLogLevelWarning = 1,
    CBLogLevelInfo = 2,
    CBLogLevelDebug = 3,
};

static CBLogLevel CBCurrentLogLevel = CBLogLevelInfo;

static NSString *CBTimestampString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });
    return [formatter stringFromDate:[NSDate date]];
}

static void CBConfigureLogLevel(void) {
    NSString *rawLevel = NSProcessInfo.processInfo.environment[@"CODEXBAR_LOG_LEVEL"];
    NSString *normalized = rawLevel.lowercaseString ?: @"";
    if ([normalized isEqualToString:@"error"]) {
        CBCurrentLogLevel = CBLogLevelError;
    } else if ([normalized isEqualToString:@"warn"] || [normalized isEqualToString:@"warning"]) {
        CBCurrentLogLevel = CBLogLevelWarning;
    } else if ([normalized isEqualToString:@"debug"]) {
        CBCurrentLogLevel = CBLogLevelDebug;
    } else {
        CBCurrentLogLevel = CBLogLevelInfo;
    }
}

static void CBLog(CBLogLevel level, NSString *message) {
    if (level > CBCurrentLogLevel) {
        return;
    }

    NSString *label = @"INFO";
    NSString *color = @"\033[90m";
    if (level == CBLogLevelError) {
        label = @"ERROR";
        color = @"\033[31m";
    } else if (level == CBLogLevelWarning) {
        label = @"WARN";
        color = @"\033[33m";
    } else if (level == CBLogLevelDebug) {
        label = @"DEBUG";
    }

    fprintf(stderr, "%s[%s] [%s] %s\033[0m\n",
            color.UTF8String,
            CBTimestampString().UTF8String,
            label.UTF8String,
            message.UTF8String);
}

@interface CBRateLimitWindow : NSObject
@property (nonatomic, assign) double usedPercent;
@property (nonatomic, assign) NSInteger windowMinutes;
@property (nonatomic, strong) NSDate *resetsAt;
@property (nonatomic, readonly) NSInteger remainingPercent;
@end

@implementation CBRateLimitWindow
- (NSInteger)remainingPercent {
    double remaining = 100.0 - self.usedPercent;
    if (remaining < 0.0) {
        remaining = 0.0;
    } else if (remaining > 100.0) {
        remaining = 100.0;
    }
    return (NSInteger)llround(remaining);
}
@end

@interface CBUsageSnapshot : NSObject
@property (nonatomic, strong) CBRateLimitWindow *primary;
@property (nonatomic, strong) CBRateLimitWindow *secondary;
@property (nonatomic, copy) NSString *planType;
@property (nonatomic, strong) NSDate *capturedAt;
@property (nonatomic, copy) NSString *sourcePath;
@end

@implementation CBUsageSnapshot
@end

@interface CBUsageSnapshotStore : NSObject
@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) NSURL *codexHomeURL;
@property (nonatomic, strong) NSURL *sessionsURL;
@property (nonatomic, strong) NSURL *archivedURL;
- (nullable CBUsageSnapshot *)loadLatestSnapshot:(NSError **)error;
@end

@implementation CBUsageSnapshotStore

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _fileManager = [NSFileManager defaultManager];
    NSURL *homeURL = NSFileManager.defaultManager.homeDirectoryForCurrentUser;
    _codexHomeURL = [homeURL URLByAppendingPathComponent:@".codex" isDirectory:YES];
    _sessionsURL = [_codexHomeURL URLByAppendingPathComponent:@"sessions" isDirectory:YES];
    _archivedURL = [_codexHomeURL URLByAppendingPathComponent:@"archived_sessions" isDirectory:YES];
    return self;
}

- (nullable CBUsageSnapshot *)loadLatestSnapshot:(NSError **)error {
    BOOL isDirectory = NO;
    if (![self.fileManager fileExistsAtPath:self.codexHomeURL.path isDirectory:&isDirectory] || !isDirectory) {
        if (error) {
            *error = [NSError errorWithDomain:@"CodexBar"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Codex 数据目录不存在: %@", self.codexHomeURL.path]}];
        }
        return nil;
    }

    NSArray<NSURL *> *recentFiles = [self recentSessionFiles:error];
    if (recentFiles.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"CodexBar"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"没有找到任何 Codex 会话文件"}];
        }
        return nil;
    }

    CBUsageSnapshot *latestSnapshot = nil;
    NSDate *latestDate = nil;
    for (NSURL *fileURL in recentFiles) {
        NSError *parseError = nil;
        CBUsageSnapshot *candidate = [self latestSnapshotFromFile:fileURL capturedAt:nil error:&parseError];
        if (parseError) {
            CBLog(CBLogLevelWarning, [NSString stringWithFormat:@"跳过解析失败的文件: %@", fileURL.path]);
            continue;
        }
        if (!candidate) {
            continue;
        }
        if (!latestSnapshot || [candidate.capturedAt compare:latestDate] == NSOrderedDescending) {
            latestSnapshot = candidate;
            latestDate = candidate.capturedAt;
        }
    }

    if (!latestSnapshot && error) {
        *error = [NSError errorWithDomain:@"CodexBar"
                                     code:3
                                 userInfo:@{NSLocalizedDescriptionKey: @"没有在最近的 Codex 会话里找到 token_count 快照"}];
    }
    return latestSnapshot;
}

- (NSArray<NSURL *> *)recentSessionFiles:(NSError **)error {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    [files addObjectsFromArray:[self sessionFilesInDirectory:self.sessionsURL error:nil]];
    [files addObjectsFromArray:[self sessionFilesInDirectory:self.archivedURL error:nil]];

    NSArray<NSURL *> *sorted = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *lhs, NSURL *rhs) {
        NSDate *lhsDate = [self modificationDateForURL:lhs] ?: [NSDate distantPast];
        NSDate *rhsDate = [self modificationDateForURL:rhs] ?: [NSDate distantPast];
        return [rhsDate compare:lhsDate];
    }];

    if (sorted.count == 0) {
        return @[];
    }

    NSUInteger count = MIN((NSUInteger)24, sorted.count);
    return [sorted subarrayWithRange:NSMakeRange(0, count)];
}

- (NSArray<NSURL *> *)sessionFilesInDirectory:(NSURL *)directoryURL error:(NSError **)error {
    BOOL isDirectory = NO;
    if (![self.fileManager fileExistsAtPath:directoryURL.path isDirectory:&isDirectory] || !isDirectory) {
        return @[];
    }

    NSDirectoryEnumerator<NSURL *> *enumerator = [self.fileManager enumeratorAtURL:directoryURL
                                                         includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLContentModificationDateKey]
                                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                       errorHandler:nil];
    NSMutableArray<NSURL *> *result = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSNumber *isRegularFile = nil;
        [url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil];
        if (isRegularFile.boolValue && [[url.pathExtension lowercaseString] isEqualToString:@"jsonl"]) {
            [result addObject:url];
        }
    }
    return result;
}

- (NSDate *)modificationDateForURL:(NSURL *)url {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date;
}

- (nullable CBUsageSnapshot *)latestSnapshotFromFile:(NSURL *)fileURL capturedAt:(NSDate * _Nullable __autoreleasing *)capturedAt error:(NSError **)error {
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:&readError];
    if (!content) {
        if (error) {
            *error = readError;
        }
        return nil;
    }

    __block CBUsageSnapshot *latestSnapshot = nil;
    __block NSDate *latestDate = nil;
    __block NSUInteger latestLineIndex = 0;
    __block NSUInteger currentLineIndex = 0;
    NSDate *fallbackDate = [self modificationDateForURL:fileURL] ?: [NSDate date];

    [content enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        currentLineIndex += 1;

        if ([line rangeOfString:@"\"type\":\"token_count\""].location == NSNotFound) {
            return;
        }

        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!lineData) {
            return;
        }

        NSError *jsonError = nil;
        id rawObject = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:&jsonError];
        if (!rawObject || ![rawObject isKindOfClass:[NSDictionary class]]) {
            return;
        }

        NSDictionary *object = (NSDictionary *)rawObject;
        NSDictionary *payload = [object[@"payload"] isKindOfClass:[NSDictionary class]] ? object[@"payload"] : nil;
        NSDictionary *info = [payload[@"info"] isKindOfClass:[NSDictionary class]] ? payload[@"info"] : nil;
        NSDictionary *rateLimits = [payload[@"rate_limits"] isKindOfClass:[NSDictionary class]] ? payload[@"rate_limits"] : nil;
        if (!rateLimits && [info[@"rate_limits"] isKindOfClass:[NSDictionary class]]) {
            rateLimits = info[@"rate_limits"];
        }
        NSDictionary *primaryDict = [rateLimits[@"primary"] isKindOfClass:[NSDictionary class]] ? rateLimits[@"primary"] : nil;
        NSDictionary *secondaryDict = [rateLimits[@"secondary"] isKindOfClass:[NSDictionary class]] ? rateLimits[@"secondary"] : nil;
        NSString *payloadType = [payload[@"type"] isKindOfClass:[NSString class]] ? payload[@"type"] : nil;

        if (![payloadType isEqualToString:@"token_count"] || !primaryDict || !secondaryDict) {
            return;
        }

        CBRateLimitWindow *primary = [self rateLimitWindowFromDictionary:primaryDict];
        CBRateLimitWindow *secondary = [self rateLimitWindowFromDictionary:secondaryDict];
        if (!primary || !secondary) {
            return;
        }

        CBUsageSnapshot *snapshot = [[CBUsageSnapshot alloc] init];
        snapshot.primary = primary;
        snapshot.secondary = secondary;
        snapshot.planType = [rateLimits[@"plan_type"] isKindOfClass:[NSString class]] ? rateLimits[@"plan_type"] : @"unknown";
        snapshot.capturedAt = [self dateFromTimestamp:object[@"timestamp"]] ?: fallbackDate;
        snapshot.sourcePath = fileURL.path;

        NSComparisonResult comparison = latestDate ? [snapshot.capturedAt compare:latestDate] : NSOrderedDescending;
        BOOL shouldReplace = !latestSnapshot || comparison == NSOrderedDescending;
        if (!shouldReplace && comparison == NSOrderedSame && currentLineIndex > latestLineIndex) {
            shouldReplace = YES;
        }

        if (shouldReplace) {
            latestSnapshot = snapshot;
            latestDate = snapshot.capturedAt;
            latestLineIndex = currentLineIndex;
        }
    }];

    if (capturedAt && latestSnapshot) {
        *capturedAt = latestDate;
    }
    return latestSnapshot;
}

- (nullable CBRateLimitWindow *)rateLimitWindowFromDictionary:(NSDictionary *)dict {
    NSNumber *usedPercent = [self numberValue:dict[@"used_percent"]];
    NSNumber *windowMinutes = [self numberValue:dict[@"window_minutes"]];
    NSNumber *resetsAt = [self numberValue:dict[@"resets_at"]];
    if (!usedPercent || !windowMinutes || !resetsAt) {
        return nil;
    }

    CBRateLimitWindow *window = [[CBRateLimitWindow alloc] init];
    window.usedPercent = usedPercent.doubleValue;
    window.windowMinutes = windowMinutes.integerValue;
    window.resetsAt = [NSDate dateWithTimeIntervalSince1970:resetsAt.doubleValue];
    return window;
}

- (NSNumber *)numberValue:(id)value {
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return @([(NSString *)value doubleValue]);
    }
    return nil;
}

- (NSDate *)dateFromTimestamp:(id)value {
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter dateFromString:(NSString *)value];
}

@end

static NSString *CBStatusBarTitle(CBUsageSnapshot *snapshot) {
    return [NSString stringWithFormat:@"C %ld%%·%ld%%",
            (long)snapshot.primary.remainingPercent,
            (long)snapshot.secondary.remainingPercent];
}

static NSDateFormatter *CBShortDateFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"MM-dd HH:mm";
    });
    return formatter;
}

static NSDateFormatter *CBFullDateFormatter(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return formatter;
}

static NSArray<NSString *> *CBDetailLines(CBUsageSnapshot *snapshot) {
    return @[
        [NSString stringWithFormat:@"5小时剩余: %ld%%", (long)snapshot.primary.remainingPercent],
        [NSString stringWithFormat:@"1周剩余: %ld%%", (long)snapshot.secondary.remainingPercent],
        [NSString stringWithFormat:@"5小时重置: %@", [CBShortDateFormatter() stringFromDate:snapshot.primary.resetsAt]],
        [NSString stringWithFormat:@"1周重置: %@", [CBShortDateFormatter() stringFromDate:snapshot.secondary.resetsAt]],
        [NSString stringWithFormat:@"计划: %@", snapshot.planType ?: @"unknown"],
        [NSString stringWithFormat:@"更新时间: %@", [CBFullDateFormatter() stringFromDate:snapshot.capturedAt]],
        [NSString stringWithFormat:@"来源: %@", snapshot.sourcePath ?: @"--"],
    ];
}

@interface CBAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) CBUsageSnapshotStore *store;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMenuItem *primaryItem;
@property (nonatomic, strong) NSMenuItem *secondaryItem;
@property (nonatomic, strong) NSMenuItem *primaryResetItem;
@property (nonatomic, strong) NSMenuItem *secondaryResetItem;
@property (nonatomic, strong) NSMenuItem *planItem;
@property (nonatomic, strong) NSMenuItem *updatedAtItem;
@property (nonatomic, strong) NSMenuItem *sourceItem;
@property (nonatomic, strong) CBUsageSnapshot *latestSnapshot;
@end

@implementation CBAppDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _store = [[CBUsageSnapshotStore alloc] init];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"C --%·--%";
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    self.statusItem.button.toolTip = @"Codex 用量尚未读取";

    NSMenu *menu = [[NSMenu alloc] init];
    self.primaryItem = [[NSMenuItem alloc] initWithTitle:@"5小时剩余: --" action:nil keyEquivalent:@""];
    self.secondaryItem = [[NSMenuItem alloc] initWithTitle:@"1周剩余: --" action:nil keyEquivalent:@""];
    self.primaryResetItem = [[NSMenuItem alloc] initWithTitle:@"5小时重置: --" action:nil keyEquivalent:@""];
    self.secondaryResetItem = [[NSMenuItem alloc] initWithTitle:@"1周重置: --" action:nil keyEquivalent:@""];
    self.planItem = [[NSMenuItem alloc] initWithTitle:@"计划: --" action:nil keyEquivalent:@""];
    self.updatedAtItem = [[NSMenuItem alloc] initWithTitle:@"更新时间: --" action:nil keyEquivalent:@""];
    self.sourceItem = [[NSMenuItem alloc] initWithTitle:@"复制来源路径" action:@selector(copySourcePath:) keyEquivalent:@""];

    NSArray<NSMenuItem *> *disabledItems = @[self.primaryItem, self.secondaryItem, self.primaryResetItem, self.secondaryResetItem, self.planItem, self.updatedAtItem];
    for (NSMenuItem *item in disabledItems) {
        item.enabled = NO;
        [menu addItem:item];
    }

    self.sourceItem.target = self;
    self.sourceItem.enabled = NO;
    [menu addItem:self.sourceItem];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"立即刷新" action:@selector(refreshSnapshot:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"打开 Codex 会话目录" action:@selector(openCodexSessions:) keyEquivalent:@"o"];
    openItem.target = self;
    [menu addItem:openItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self refreshSnapshot:nil];

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                         target:self
                                                       selector:@selector(refreshSnapshot:)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.refreshTimer invalidate];
}

- (void)applySnapshot:(CBUsageSnapshot *)snapshot {
    self.latestSnapshot = snapshot;
    self.statusItem.button.title = CBStatusBarTitle(snapshot);
    self.statusItem.button.toolTip = [CBDetailLines(snapshot) componentsJoinedByString:@"\n"];

    self.primaryItem.title = [NSString stringWithFormat:@"5小时剩余: %ld%%", (long)snapshot.primary.remainingPercent];
    self.secondaryItem.title = [NSString stringWithFormat:@"1周剩余: %ld%%", (long)snapshot.secondary.remainingPercent];
    self.primaryResetItem.title = [NSString stringWithFormat:@"5小时重置: %@", [CBShortDateFormatter() stringFromDate:snapshot.primary.resetsAt]];
    self.secondaryResetItem.title = [NSString stringWithFormat:@"1周重置: %@", [CBShortDateFormatter() stringFromDate:snapshot.secondary.resetsAt]];
    self.planItem.title = [NSString stringWithFormat:@"计划: %@", snapshot.planType ?: @"unknown"];
    self.updatedAtItem.title = [NSString stringWithFormat:@"更新时间: %@", [CBFullDateFormatter() stringFromDate:snapshot.capturedAt]];
    self.sourceItem.enabled = YES;
}

- (void)applyError:(NSError *)error {
    self.statusItem.button.title = @"C --%·--%";
    self.statusItem.button.toolTip = error.localizedDescription;
    self.primaryItem.title = @"5小时剩余: --";
    self.secondaryItem.title = @"1周剩余: --";
    self.primaryResetItem.title = @"5小时重置: --";
    self.secondaryResetItem.title = @"1周重置: --";
    self.planItem.title = @"计划: --";
    self.updatedAtItem.title = @"更新时间: --";
    self.sourceItem.enabled = NO;
}

- (void)refreshSnapshot:(id)sender {
    NSError *error = nil;
    CBUsageSnapshot *snapshot = [self.store loadLatestSnapshot:&error];
    if (snapshot) {
        [self applySnapshot:snapshot];
        CBLog(CBLogLevelDebug, @"已刷新 Codex 用量快照");
        return;
    }

    [self applyError:error];
    CBLog(CBLogLevelError, error.localizedDescription ?: @"读取 Codex 用量失败");
}

- (void)copySourcePath:(id)sender {
    if (!self.latestSnapshot.sourcePath.length) {
        NSBeep();
        return;
    }

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard setString:self.latestSnapshot.sourcePath forType:NSPasteboardTypeString];
}

- (void)openCodexSessions:(id)sender {
    NSURL *sessionsURL = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@".codex/sessions" isDirectory:YES];
    [NSWorkspace.sharedWorkspace openURL:sessionsURL];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

static int CBPrintSnapshot(void) {
    CBUsageSnapshotStore *store = [[CBUsageSnapshotStore alloc] init];
    NSError *error = nil;
    CBUsageSnapshot *snapshot = [store loadLatestSnapshot:&error];
    if (!snapshot) {
        CBLog(CBLogLevelError, error.localizedDescription ?: @"读取 Codex 用量失败");
        return 1;
    }

    for (NSString *line in CBDetailLines(snapshot)) {
        printf("%s\n", line.UTF8String);
    }
    return 0;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        CBConfigureLogLevel();

        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if ([arguments containsObject:@"--snapshot"]) {
            return CBPrintSnapshot();
        }

        NSApplication *application = [NSApplication sharedApplication];
        CBAppDelegate *delegate = [[CBAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
