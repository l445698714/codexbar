#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import <fcntl.h>
#import <math.h>
#import <sqlite3.h>
#import <unistd.h>

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

@interface CBResolvedRateLimitWindow : NSObject
@property (nonatomic, assign) NSInteger remainingPercent;
@property (nonatomic, strong) NSDate *nextResetAt;
@property (nonatomic, assign) BOOL inferredFullReset;
@end

@implementation CBResolvedRateLimitWindow
@end

static CBResolvedRateLimitWindow *CBResolveWindow(CBRateLimitWindow *window, NSDate *now);
static NSImage *CBMakePieStatusImage(NSInteger remainingPercent, BOOL hasData);

@interface CBUsageSnapshot : NSObject
@property (nonatomic, strong) CBRateLimitWindow *primary;
@property (nonatomic, strong) CBRateLimitWindow *secondary;
@property (nonatomic, copy) NSString *planType;
@property (nonatomic, strong) NSDate *capturedAt;
@property (nonatomic, copy) NSString *sourcePath;
@property (nonatomic, assign) unsigned long long sourceSequence;
@end

@implementation CBUsageSnapshot
@end

@interface CBTrackedFileState : NSObject
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSDate *modificationDate;
@property (nonatomic, strong) NSMutableData *pendingLineData;
@property (nonatomic, strong) CBUsageSnapshot *latestSnapshot;
@property (nonatomic, assign) unsigned long long lineSequence;
@property (nonatomic, assign) unsigned long long readOffset;
@end

@implementation CBTrackedFileState
@end

@interface CBUsageSnapshotStore : NSObject
@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, strong) NSURL *codexHomeURL;
@property (nonatomic, strong) NSURL *sessionsURL;
@property (nonatomic, strong) NSURL *archivedURL;
@property (nonatomic, strong) NSURL *logsDatabaseURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBTrackedFileState *> *trackedStates;
@property (nonatomic, strong) NSArray<NSURL *> *trackedFiles;
@property (nonatomic, assign) BOOL hasPerformedInitialScan;
- (nullable CBUsageSnapshot *)loadLatestSnapshot:(NSError **)error;
- (NSArray<NSString *> *)watchPaths;
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
    _logsDatabaseURL = [_codexHomeURL URLByAppendingPathComponent:@"logs_2.sqlite" isDirectory:NO];
    _trackedStates = [NSMutableDictionary dictionary];
    _trackedFiles = @[];
    _hasPerformedInitialScan = NO;
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

    [self synchronizeTrackedFiles:recentFiles];

    CBUsageSnapshot *latestSnapshot = nil;
    for (NSURL *fileURL in recentFiles) {
        NSError *updateError = nil;
        [self refreshStateForFile:fileURL forceFull:!self.hasPerformedInitialScan error:&updateError];
        if (updateError) {
            CBLog(CBLogLevelWarning, [NSString stringWithFormat:@"跳过解析失败的文件: %@", fileURL.path]);
            continue;
        }

        CBTrackedFileState *state = self.trackedStates[fileURL.path];
        CBUsageSnapshot *candidate = state.latestSnapshot;
        if (!candidate) {
            continue;
        }

        if (!latestSnapshot || [self snapshot:candidate isNewerThan:latestSnapshot]) {
            latestSnapshot = candidate;
        }
    }

    NSError *logsError = nil;
    CBUsageSnapshot *logsSnapshot = [self latestSnapshotFromLogs:&logsError];
    if (logsError) {
        CBLog(CBLogLevelWarning, [NSString stringWithFormat:@"读取 logs_2.sqlite 失败: %@", logsError.localizedDescription]);
    } else if (logsSnapshot && (!latestSnapshot || [self snapshot:logsSnapshot isNewerThan:latestSnapshot])) {
        latestSnapshot = logsSnapshot;
    }

    self.hasPerformedInitialScan = YES;

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

- (void)synchronizeTrackedFiles:(NSArray<NSURL *> *)recentFiles {
    self.trackedFiles = [recentFiles copy];

    NSMutableSet<NSString *> *activePaths = [NSMutableSet set];
    for (NSURL *fileURL in recentFiles) {
        [activePaths addObject:fileURL.path];
        if (!self.trackedStates[fileURL.path]) {
            CBTrackedFileState *state = [[CBTrackedFileState alloc] init];
            state.fileURL = fileURL;
            state.pendingLineData = [NSMutableData data];
            state.readOffset = 0;
            self.trackedStates[fileURL.path] = state;
        }
    }

    for (NSString *path in [self.trackedStates allKeys]) {
        if (![activePaths containsObject:path]) {
            [self.trackedStates removeObjectForKey:path];
        }
    }
}

- (NSDate *)modificationDateForURL:(NSURL *)url {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date;
}

- (BOOL)snapshot:(CBUsageSnapshot *)candidate isNewerThan:(CBUsageSnapshot *)current {
    if (!current) {
        return YES;
    }

    NSComparisonResult comparison = [candidate.capturedAt compare:current.capturedAt];
    if (comparison == NSOrderedDescending) {
        return YES;
    }
    if (comparison == NSOrderedSame) {
        return candidate.sourceSequence >= current.sourceSequence;
    }
    return NO;
}

- (void)refreshStateForFile:(NSURL *)fileURL forceFull:(BOOL)forceFull error:(NSError **)error {
    NSDictionary<NSFileAttributeKey, id> *attributes = [self.fileManager attributesOfItemAtPath:fileURL.path error:error];
    if (!attributes) {
        return;
    }

    CBTrackedFileState *state = self.trackedStates[fileURL.path];
    if (!state) {
        state = [[CBTrackedFileState alloc] init];
        state.fileURL = fileURL;
        state.pendingLineData = [NSMutableData data];
        state.readOffset = 0;
        self.trackedStates[fileURL.path] = state;
    }

    unsigned long long fileSize = [attributes fileSize];
    NSDate *modificationDate = attributes[NSFileModificationDate] ?: [NSDate date];

    if (!forceFull) {
        if (fileSize == state.readOffset && state.modificationDate && [modificationDate compare:state.modificationDate] != NSOrderedDescending) {
            return;
        }

        if (fileSize < state.readOffset || (fileSize == state.readOffset && state.modificationDate && ![modificationDate isEqualToDate:state.modificationDate])) {
            forceFull = YES;
        }
    }

    if (forceFull) {
        state.readOffset = 0;
        state.lineSequence = 0;
        state.latestSnapshot = nil;
        state.pendingLineData = [NSMutableData data];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:fileURL error:error];
    if (!handle) {
        return;
    }

    @try {
        [handle seekToFileOffset:state.readOffset];
        NSData *newData = [handle readDataToEndOfFile];
        if (!forceFull && newData.length == 0) {
            state.modificationDate = modificationDate;
            return;
        }

        if (newData.length > 0) {
            [state.pendingLineData appendData:newData];
            [self consumeBufferedLinesForState:state fallbackDate:modificationDate];
        }

        state.readOffset = fileSize;
        state.modificationDate = modificationDate;
    } @finally {
        [handle closeFile];
    }
}

- (void)consumeBufferedLinesForState:(CBTrackedFileState *)state fallbackDate:(NSDate *)fallbackDate {
    const uint8_t *bytes = state.pendingLineData.bytes;
    NSUInteger length = state.pendingLineData.length;
    NSUInteger lineStart = 0;
    NSUInteger lastConsumedIndex = NSNotFound;

    for (NSUInteger index = 0; index < length; index += 1) {
        if (bytes[index] != '\n') {
            continue;
        }

        NSUInteger lineLength = index - lineStart;
        if (lineLength > 0 && bytes[index - 1] == '\r') {
            lineLength -= 1;
        }

        NSData *lineData = [state.pendingLineData subdataWithRange:NSMakeRange(lineStart, lineLength)];
        if (lineData.length > 0) {
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (line.length > 0) {
                [self updateState:state withJSONLLine:line fallbackDate:fallbackDate];
            }
        }

        lastConsumedIndex = index;
        lineStart = index + 1;
    }

    if (lastConsumedIndex == NSNotFound) {
        return;
    }

    NSData *remainingData = (lineStart < length)
        ? [state.pendingLineData subdataWithRange:NSMakeRange(lineStart, length - lineStart)]
        : [NSData data];
    state.pendingLineData = [remainingData mutableCopy];
}

- (void)updateState:(CBTrackedFileState *)state withJSONLLine:(NSString *)line fallbackDate:(NSDate *)fallbackDate {
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
    snapshot.sourcePath = state.fileURL.path;
    snapshot.sourceSequence = ++state.lineSequence;

    if ([self snapshot:snapshot isNewerThan:state.latestSnapshot]) {
        state.latestSnapshot = snapshot;
    }
}

- (NSArray<NSString *> *)watchPaths {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    [paths addObject:self.sessionsURL.path];
    [paths addObject:self.archivedURL.path];
    [paths addObject:self.logsDatabaseURL.path];

    for (NSURL *fileURL in self.trackedFiles) {
        [paths addObject:fileURL.path];
        if (fileURL.URLByDeletingLastPathComponent.path.length > 0) {
            [paths addObject:fileURL.URLByDeletingLastPathComponent.path];
        }
    }

    return paths.array;
}

- (nullable CBUsageSnapshot *)latestSnapshotFromLogs:(NSError **)error {
    if (![self.fileManager fileExistsAtPath:self.logsDatabaseURL.path]) {
        return nil;
    }

    sqlite3 *database = NULL;
    int openResult = sqlite3_open_v2(self.logsDatabaseURL.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY, NULL);
    if (openResult != SQLITE_OK || !database) {
        if (error) {
            NSString *message = database ? [NSString stringWithUTF8String:sqlite3_errmsg(database)] : @"无法打开 logs_2.sqlite";
            *error = [NSError errorWithDomain:@"CodexBar" code:4 userInfo:@{NSLocalizedDescriptionKey: message ?: @"无法打开 logs_2.sqlite"}];
        }
        if (database) {
            sqlite3_close(database);
        }
        return nil;
    }

    const char *sql =
        "SELECT id, ts, feedback_log_body "
        "FROM logs "
        "WHERE feedback_log_body LIKE '%codex.rate_limits%' "
        "ORDER BY id DESC "
        "LIMIT 100";

    sqlite3_stmt *statement = NULL;
    int prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, NULL);
    if (prepareResult != SQLITE_OK) {
        if (error) {
            *error = [NSError errorWithDomain:@"CodexBar"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(database)] ?: @"无法查询 logs_2.sqlite"}];
        }
        sqlite3_close(database);
        return nil;
    }

    CBUsageSnapshot *latestSnapshot = nil;
    while (sqlite3_step(statement) == SQLITE_ROW) {
        sqlite3_int64 rowIdentifier = sqlite3_column_int64(statement, 0);
        sqlite3_int64 timestampValue = sqlite3_column_int64(statement, 1);
        const unsigned char *bodyText = sqlite3_column_text(statement, 2);
        if (!bodyText) {
            continue;
        }

        NSString *body = [NSString stringWithUTF8String:(const char *)bodyText];
        NSDate *capturedAt = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)timestampValue];
        CBUsageSnapshot *snapshot = [self snapshotFromLogsBody:body capturedAt:capturedAt rowIdentifier:(unsigned long long)rowIdentifier];
        if (!snapshot) {
            continue;
        }

        if (!latestSnapshot || [self snapshot:snapshot isNewerThan:latestSnapshot]) {
            latestSnapshot = snapshot;
        }
    }

    sqlite3_finalize(statement);
    sqlite3_close(database);
    return latestSnapshot;
}

- (nullable CBUsageSnapshot *)snapshotFromLogsBody:(NSString *)body
                                        capturedAt:(NSDate *)capturedAt
                                     rowIdentifier:(unsigned long long)rowIdentifier {
    NSRange markerRange = [body rangeOfString:@"{\"type\":\"codex.rate_limits\""];
    if (markerRange.location == NSNotFound) {
        return nil;
    }

    NSString *jsonText = [body substringFromIndex:markerRange.location];
    NSData *jsonData = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) {
        return nil;
    }

    NSError *jsonError = nil;
    id rawObject = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
    if (!rawObject || ![rawObject isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *object = (NSDictionary *)rawObject;
    NSDictionary *rateLimits = [object[@"rate_limits"] isKindOfClass:[NSDictionary class]] ? object[@"rate_limits"] : nil;
    NSDictionary *primaryDict = [rateLimits[@"primary"] isKindOfClass:[NSDictionary class]] ? rateLimits[@"primary"] : nil;
    NSDictionary *secondaryDict = [rateLimits[@"secondary"] isKindOfClass:[NSDictionary class]] ? rateLimits[@"secondary"] : nil;
    if (!rateLimits || !primaryDict || !secondaryDict) {
        return nil;
    }

    CBRateLimitWindow *primary = [self rateLimitWindowFromRateLimitEventDictionary:primaryDict];
    CBRateLimitWindow *secondary = [self rateLimitWindowFromRateLimitEventDictionary:secondaryDict];
    if (!primary || !secondary) {
        return nil;
    }

    CBUsageSnapshot *snapshot = [[CBUsageSnapshot alloc] init];
    snapshot.primary = primary;
    snapshot.secondary = secondary;
    snapshot.planType = [object[@"plan_type"] isKindOfClass:[NSString class]] ? object[@"plan_type"] : @"unknown";
    snapshot.capturedAt = capturedAt;
    snapshot.sourcePath = self.logsDatabaseURL.path;
    snapshot.sourceSequence = rowIdentifier;
    return snapshot;
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

- (nullable CBRateLimitWindow *)rateLimitWindowFromRateLimitEventDictionary:(NSDictionary *)dict {
    NSNumber *usedPercent = [self numberValue:dict[@"used_percent"]];
    NSNumber *windowMinutes = [self numberValue:dict[@"window_minutes"]];
    NSNumber *resetAt = [self numberValue:dict[@"reset_at"]];
    if (!usedPercent || !windowMinutes || !resetAt) {
        return nil;
    }

    CBRateLimitWindow *window = [[CBRateLimitWindow alloc] init];
    window.usedPercent = usedPercent.doubleValue;
    window.windowMinutes = windowMinutes.integerValue;
    window.resetsAt = [NSDate dateWithTimeIntervalSince1970:resetAt.doubleValue];
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

static NSImage *CBMakePieStatusImage(NSInteger remainingPercent, BOOL hasData) {
    NSSize size = NSMakeSize(14.0, 14.0);
    NSRect bounds = NSMakeRect(0.0, 0.0, size.width, size.height);
    NSRect circleRect = NSInsetRect(bounds, 1.0, 1.0);
    CGFloat radius = circleRect.size.width / 2.0;
    NSPoint center = NSMakePoint(NSMidX(circleRect), NSMidY(circleRect));

    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];

    [[NSColor clearColor] setFill];
    NSRectFill(bounds);

    NSBezierPath *outlinePath = [NSBezierPath bezierPathWithOvalInRect:circleRect];
    outlinePath.lineWidth = 1.2;

    BOOL useColor = NO;
    if (hasData) {
        NSInteger clampedRemaining = MAX(0, MIN(100, remainingPercent));
        useColor = clampedRemaining < 10;

        NSColor *fillColor = useColor ? [NSColor systemRedColor] : [NSColor blackColor];

        if (clampedRemaining >= 100) {
            [fillColor setFill];
            [outlinePath fill];
        } else if (clampedRemaining > 0) {
            CGFloat sweepDegrees = 360.0 * ((CGFloat)clampedRemaining / 100.0);
            NSBezierPath *slicePath = [NSBezierPath bezierPath];
            [slicePath moveToPoint:center];
            [slicePath appendBezierPathWithArcWithCenter:center
                                                  radius:radius
                                              startAngle:90.0
                                                endAngle:90.0 - sweepDegrees
                                               clockwise:YES];
            [slicePath closePath];
            [fillColor setFill];
            [slicePath fill];
        }

        if (useColor) {
            BOOL isDark = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:
                @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]] == NSAppearanceNameDarkAqua;
            [[NSColor colorWithWhite:(isDark ? 1.0 : 0.0) alpha:0.85] setStroke];
        } else {
            [[NSColor colorWithWhite:0.0 alpha:0.95] setStroke];
        }
    } else {
        [[NSColor colorWithWhite:0.0 alpha:0.65] setStroke];
    }

    [outlinePath stroke];
    [image unlockFocus];
    image.template = !useColor;
    return image;
}

static NSString *CBStatusBarTitle(CBUsageSnapshot *snapshot) {
    NSDate *now = [NSDate date];
    CBResolvedRateLimitWindow *primary = CBResolveWindow(snapshot.primary, now);
    CBResolvedRateLimitWindow *secondary = CBResolveWindow(snapshot.secondary, now);
    return [NSString stringWithFormat:@"%ld%%·%ld%%",
            (long)primary.remainingPercent,
            (long)secondary.remainingPercent];
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

static CBResolvedRateLimitWindow *CBResolveWindow(CBRateLimitWindow *window, NSDate *now) {
    CBResolvedRateLimitWindow *resolved = [[CBResolvedRateLimitWindow alloc] init];
    if (!window || !window.resetsAt) {
        resolved.remainingPercent = 0;
        resolved.nextResetAt = now;
        resolved.inferredFullReset = NO;
        return resolved;
    }

    if ([now compare:window.resetsAt] == NSOrderedAscending) {
        resolved.remainingPercent = window.remainingPercent;
        resolved.nextResetAt = window.resetsAt;
        resolved.inferredFullReset = NO;
        return resolved;
    }

    NSTimeInterval interval = MAX((NSTimeInterval)(window.windowMinutes * 60), 60.0);
    NSTimeInterval elapsed = [now timeIntervalSinceDate:window.resetsAt];
    long long windowsPassed = (long long)floor(elapsed / interval) + 1;

    resolved.remainingPercent = 100;
    resolved.nextResetAt = [window.resetsAt dateByAddingTimeInterval:(NSTimeInterval)windowsPassed * interval];
    resolved.inferredFullReset = YES;
    return resolved;
}

static NSArray<NSString *> *CBDetailLines(CBUsageSnapshot *snapshot) {
    NSDate *now = [NSDate date];
    CBResolvedRateLimitWindow *primary = CBResolveWindow(snapshot.primary, now);
    CBResolvedRateLimitWindow *secondary = CBResolveWindow(snapshot.secondary, now);

    NSString *primaryNote = primary.inferredFullReset ? @" (按重置时间推断已回满)" : @"";
    NSString *secondaryNote = secondary.inferredFullReset ? @" (按重置时间推断已回满)" : @"";

    return @[
        [NSString stringWithFormat:@"5小时剩余: %ld%%%@" , (long)primary.remainingPercent, primaryNote],
        [NSString stringWithFormat:@"1周剩余: %ld%%%@" , (long)secondary.remainingPercent, secondaryNote],
        [NSString stringWithFormat:@"5小时重置: %@", [CBShortDateFormatter() stringFromDate:primary.nextResetAt]],
        [NSString stringWithFormat:@"1周重置: %@", [CBShortDateFormatter() stringFromDate:secondary.nextResetAt]],
        [NSString stringWithFormat:@"计划: %@", snapshot.planType ?: @"unknown"],
        [NSString stringWithFormat:@"更新时间: %@", [CBFullDateFormatter() stringFromDate:snapshot.capturedAt]],
        [NSString stringWithFormat:@"来源: %@", snapshot.sourcePath ?: @"--"],
    ];
}

@interface CBAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (nonatomic, strong) CBUsageSnapshotStore *store;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *watchSources;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *watchDescriptors;
@property (nonatomic, strong) dispatch_source_t idleRefreshTimer;
@property (nonatomic, strong) NSMenuItem *primaryItem;
@property (nonatomic, strong) NSMenuItem *secondaryItem;
@property (nonatomic, strong) NSMenuItem *primaryResetItem;
@property (nonatomic, strong) NSMenuItem *secondaryResetItem;
@property (nonatomic, strong) NSMenuItem *planItem;
@property (nonatomic, strong) NSMenuItem *updatedAtItem;
@property (nonatomic, strong) NSMenuItem *sourceItem;
@property (nonatomic, strong) NSMenuItem *launchAtLoginItem;
@property (nonatomic, strong) CBUsageSnapshot *latestSnapshot;
@end

@implementation CBAppDelegate

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _store = [[CBUsageSnapshotStore alloc] init];
    _watchSources = [NSMutableDictionary dictionary];
    _watchDescriptors = [NSMutableDictionary dictionary];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"--%·--%";
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    self.statusItem.button.image = CBMakePieStatusImage(0, NO);
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.toolTip = @"Codex 用量尚未读取";

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
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

    self.launchAtLoginItem = [[NSMenuItem alloc] initWithTitle:@"开机自启" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    self.launchAtLoginItem.target = self;
    [menu addItem:self.launchAtLoginItem];
    [self updateLaunchAtLoginItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self refreshSnapshot:nil];
    [self synchronizeWatchers];

    self.refreshTimer = [NSTimer timerWithTimeInterval:5.0
                                                target:self
                                              selector:@selector(refreshSnapshot:)
                                              userInfo:nil
                                               repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.refreshTimer invalidate];
    [self tearDownWatchers];
    if (self.idleRefreshTimer) {
        dispatch_source_cancel(self.idleRefreshTimer);
        self.idleRefreshTimer = nil;
    }
}

- (void)applySnapshot:(CBUsageSnapshot *)snapshot {
    self.latestSnapshot = snapshot;
    NSDate *now = [NSDate date];
    CBResolvedRateLimitWindow *primary = CBResolveWindow(snapshot.primary, now);
    CBResolvedRateLimitWindow *secondary = CBResolveWindow(snapshot.secondary, now);

    self.statusItem.button.image = CBMakePieStatusImage(primary.remainingPercent, YES);
    self.statusItem.button.title = CBStatusBarTitle(snapshot);
    self.statusItem.button.toolTip = [CBDetailLines(snapshot) componentsJoinedByString:@"\n"];

    self.primaryItem.title = [NSString stringWithFormat:@"5小时剩余: %ld%%%@", (long)primary.remainingPercent, primary.inferredFullReset ? @" (已回满)" : @""];
    self.secondaryItem.title = [NSString stringWithFormat:@"1周剩余: %ld%%%@", (long)secondary.remainingPercent, secondary.inferredFullReset ? @" (已回满)" : @""];
    self.primaryResetItem.title = [NSString stringWithFormat:@"5小时重置: %@", [CBShortDateFormatter() stringFromDate:primary.nextResetAt]];
    self.secondaryResetItem.title = [NSString stringWithFormat:@"1周重置: %@", [CBShortDateFormatter() stringFromDate:secondary.nextResetAt]];
    self.planItem.title = [NSString stringWithFormat:@"计划: %@", snapshot.planType ?: @"unknown"];
    self.updatedAtItem.title = [NSString stringWithFormat:@"更新时间: %@", [CBFullDateFormatter() stringFromDate:snapshot.capturedAt]];
    self.sourceItem.enabled = YES;
}

- (void)applyError:(NSError *)error {
    self.statusItem.button.image = CBMakePieStatusImage(0, NO);
    self.statusItem.button.title = @"--%·--%";
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
    [self synchronizeWatchers];
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

- (void)toggleLaunchAtLogin:(id)sender {
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL shouldDisable = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval;
    BOOL success = shouldDisable ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (!success) {
        NSString *action = shouldDisable ? @"关闭开机自启失败" : @"开启开机自启失败";
        CBLog(CBLogLevelError, [NSString stringWithFormat:@"%@: %@", action, error.localizedDescription ?: @"未知错误"]);
        [self showLaunchAtLoginError:error action:action];
    }

    [self updateLaunchAtLoginItem];
}

- (void)updateLaunchAtLoginItem {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.launchAtLoginItem.enabled = YES;

    if (status == SMAppServiceStatusEnabled) {
        self.launchAtLoginItem.title = @"开机自启";
        self.launchAtLoginItem.state = NSControlStateValueOn;
    } else if (status == SMAppServiceStatusRequiresApproval) {
        self.launchAtLoginItem.title = @"开机自启（需要系统授权）";
        self.launchAtLoginItem.state = NSControlStateValueMixed;
    } else {
        self.launchAtLoginItem.title = @"开机自启";
        self.launchAtLoginItem.state = NSControlStateValueOff;
    }
}

- (void)showLaunchAtLoginError:(NSError *)error action:(NSString *)action {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = action;
    alert.informativeText = error.localizedDescription ?: @"请在系统设置的登录项中检查 CodexBar 权限。";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateLaunchAtLoginItem];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

- (void)synchronizeWatchers {
    NSArray<NSString *> *watchPaths = [self.store watchPaths];
    NSMutableSet<NSString *> *activePaths = [NSMutableSet setWithArray:watchPaths];

    for (NSString *path in watchPaths) {
        if (self.watchSources[path]) {
            continue;
        }

        int descriptor = open(path.fileSystemRepresentation, O_EVTONLY);
        if (descriptor < 0) {
            continue;
        }

        unsigned long mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_ATTRIB | DISPATCH_VNODE_LINK;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)descriptor, mask, dispatch_get_main_queue());
        if (!source) {
            close(descriptor);
            continue;
        }

        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(source, ^{
            [weakSelf scheduleRefreshFromWatcherForPath:path];
        });
        dispatch_source_set_cancel_handler(source, ^{
            close(descriptor);
        });
        dispatch_resume(source);

        self.watchSources[path] = source;
        self.watchDescriptors[path] = @(descriptor);
    }

    for (NSString *path in [self.watchSources allKeys]) {
        if ([activePaths containsObject:path]) {
            continue;
        }

        dispatch_source_t source = self.watchSources[path];
        [self.watchSources removeObjectForKey:path];
        [self.watchDescriptors removeObjectForKey:path];
        dispatch_source_cancel(source);
    }
}

- (void)tearDownWatchers {
    for (NSString *path in [self.watchSources allKeys]) {
        dispatch_source_t source = self.watchSources[path];
        dispatch_source_cancel(source);
    }
    [self.watchSources removeAllObjects];
    [self.watchDescriptors removeAllObjects];
}

- (void)scheduleRefreshFromWatcherForPath:(NSString *)path {
    CBLog(CBLogLevelDebug, [NSString stringWithFormat:@"检测到文件变化: %@", path]);

    if (self.idleRefreshTimer) {
        dispatch_source_cancel(self.idleRefreshTimer);
        self.idleRefreshTimer = nil;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (int64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        CBLog(CBLogLevelDebug, @"会话文件已安静 2 秒，执行刷新");
        [strongSelf refreshSnapshot:nil];
        if (strongSelf.idleRefreshTimer) {
            dispatch_source_cancel(strongSelf.idleRefreshTimer);
            strongSelf.idleRefreshTimer = nil;
        }
    });
    dispatch_resume(timer);
    self.idleRefreshTimer = timer;
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
