//
//  Tweak.x
//  SWRunCheckpointHUD
//
//  Dopamine (rootless) 越狱注入 - 运动世界校园跑悬浮窗插件
//  功能: 拦截打卡点数据, 悬浮窗显示必经点位(红色)和普通点位(蓝色)
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <sys/proc.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>
#import "SWRunFloatingView.h"
#import "SWRunRoutePlanner.h"
#import "SWRunSimulator.h"

@interface NSURLSession (SWRunCheckpointHUD)
- (void)swrun_processResponseData:(NSData *)data;
@end

// ============================================================
#pragma mark - 辅助函数: JSON 解析
// ============================================================

static id SWRunJSONFromString(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length < 2) return nil;

    NSString *lower = [value lowercaseString];
    BOOL maybePoints = [lower containsString:@"isfixed"] ||
                       [lower containsString:@"pointname"] ||
                       [lower containsString:@"pointsresmodels"] ||
                       [lower containsString:@"fivepoint"];
    if (!maybePoints) return nil;

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    return err ? nil : obj;
}

static id SWRunValueForKeys(NSDictionary *dict, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = dict[key];
        if (value && value != [NSNull null]) return value;
    }
    return nil;
}

static double SWRunDoubleFromObject(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value doubleValue];
    return 0;
}

static BOOL SWRunBoolFromObject(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        return [lower isEqualToString:@"1"] ||
               [lower isEqualToString:@"true"] ||
               [lower isEqualToString:@"yes"];
    }
    return NO;
}

static BOOL SWRunDictionaryLooksLikeCheckpoint(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return NO;

    id latObj = SWRunValueForKeys(dict, @[@"lat", @"glat", @"gLat", @"latitude"]);
    id lonObj = SWRunValueForKeys(dict, @[@"lon", @"lng", @"glon", @"gLng", @"longitude"]);
    if (!latObj || !lonObj) return NO;

    double lat = SWRunDoubleFromObject(latObj);
    double lon = SWRunDoubleFromObject(lonObj);
    if (fabs(lat) < 0.000001 || fabs(lon) < 0.000001) return NO;

    return dict[@"isFixed"] != nil ||
           dict[@"isPass"] != nil ||
           dict[@"pointName"] != nil ||
           dict[@"fixed"] != nil;
}

static NSArray<NSDictionary *> *SWRunPointArrayFromArray(NSArray *array) {
    if (![array isKindOfClass:[NSArray class]] || array.count == 0) return nil;

    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (id item in array) {
        if ([item isKindOfClass:[NSDictionary class]] &&
            SWRunDictionaryLooksLikeCheckpoint((NSDictionary *)item)) {
            [points addObject:item];
        }
    }
    return points.count > 0 ? points : nil;
}

/// 从 JSON 对象中提取打卡点数组
static NSArray<NSDictionary *> *ExtractPointsFromJSON(id jsonObject) {
    if (!jsonObject) return nil;

    if ([jsonObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObject;

        if (SWRunDictionaryLooksLikeCheckpoint(dict)) {
            return @[dict];
        }

        NSArray *directPoints = SWRunPointArrayFromArray(dict[@"pointsResModels"]);
        if (directPoints) return directPoints;

        NSDictionary *data = dict[@"data"];
        if ([data isKindOfClass:[NSDictionary class]]) {
            NSArray *dataPoints = SWRunPointArrayFromArray(data[@"pointsResModels"]);
            if (dataPoints) return dataPoints;
        }

        NSArray<NSString *> *pointJsonKeys = @[@"fivePointJson", @"fivePoints", @"fixed_point_json"];
        for (NSString *key in pointJsonKeys) {
            id value = dict[key];
            id parsed = [value isKindOfClass:[NSString class]] ? SWRunJSONFromString(value) : value;
            NSArray<NSDictionary *> *nestedPoints = ExtractPointsFromJSON(parsed);
            if (nestedPoints) return nestedPoints;
        }

        for (id value in dict.allValues) {
            if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
                NSArray<NSDictionary *> *nestedPoints = ExtractPointsFromJSON(value);
                if (nestedPoints) return nestedPoints;
            } else if ([value isKindOfClass:[NSString class]]) {
                NSArray<NSDictionary *> *nestedPoints = ExtractPointsFromJSON(SWRunJSONFromString(value));
                if (nestedPoints) return nestedPoints;
            }
        }
    }

    if ([jsonObject isKindOfClass:[NSArray class]]) {
        NSArray<NSDictionary *> *points = SWRunPointArrayFromArray((NSArray *)jsonObject);
        if (points) return points;

        for (id value in (NSArray *)jsonObject) {
            NSArray<NSDictionary *> *nestedPoints = ExtractPointsFromJSON(value);
            if (nestedPoints) return nestedPoints;
        }
    }

    return nil;
}

/// 解析单个打卡点为模型
static SWRunCheckpoint *ParseCheckpoint(NSDictionary *pointDict) {
    SWRunCheckpoint *cp = [[SWRunCheckpoint alloc] init];

    cp.pointName = pointDict[@"pointName"] ?: @"未知点位";
    cp.isFixed   = SWRunBoolFromObject(SWRunValueForKeys(pointDict, @[@"isFixed", @"fixed"]));
    cp.isPassed  = SWRunBoolFromObject(pointDict[@"isPass"]);
    cp.position  = [pointDict[@"position"] integerValue];

    // 坐标处理
    id lonObj = SWRunValueForKeys(pointDict, @[@"lon", @"lng", @"glon", @"gLng", @"longitude"]);
    id latObj = SWRunValueForKeys(pointDict, @[@"lat", @"glat", @"gLat", @"latitude"]);

    cp.longitude = SWRunDoubleFromObject(lonObj);
    cp.latitude  = SWRunDoubleFromObject(latObj);

    return cp;
}

static BOOL SWRunDataLooksPointRelated(NSData *data) {
    if (!data || data.length < 10) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (body.length == 0) return NO;

    NSString *lower = [body lowercaseString];
    return [lower containsString:@"pointsresmodels"] ||
           [lower containsString:@"fivepointjson"] ||
           ([lower containsString:@"isfixed"] &&
            ([lower containsString:@"pointname"] ||
             ([lower containsString:@"lat"] && [lower containsString:@"lon"])));
}

/// 检测是否跑步相关 URL
static BOOL IsRunningRelatedURL(NSString *urlString) {
    if (!urlString) return NO;
    NSArray *keywords = @[@"running", @"runtrack", @"sportrecord",
                          @"fivepoint", @"pointsres", @"startsport",
                          @"sport/start", @"sport/point", @"sport/save",
                          @"sport/run", @"gps/upload", @"location/upload",
                          @"/api/points/", @"/destinationrun/points",
                          @"alllocjson", @"fivepointjson",
                          @"facecheck", @"antcheating", @"hardware"];
    NSString *lower = [urlString lowercaseString];
    for (NSString *kw in keywords) {
        if ([lower containsString:kw]) return YES;
    }
    return NO;
}

static BOOL SWRunStringLooksLikeJailbreakPath(NSString *value) {
    if (value.length == 0) return NO;
    NSString *lower = [value lowercaseString];
    NSArray *blocked = @[
        @"/applications/cydia.app",
        @"/applications/sileo.app",
        @"/applications/zebra.app",
        @"/applications/filza.app",
        @"/library/mobilesubstrate",
        @"/usr/lib/substrate",
        @"/usr/lib/libsubstitute",
        @"/usr/lib/libhooker",
        @"/usr/lib/frida",
        @"/private/var/lib/apt",
        @"/var/lib/apt",
        @"/private/var/stash",
        @"/var/jb",
        @"/bin/bash",
        @"/usr/sbin/sshd",
        @"/etc/apt",
        @"/usr/bin/cycript",
        @"frida",
        @"substrate",
        @"substitute",
        @"libhooker",
        @"cycript",
        @"dopamine"
    ];
    for (NSString *item in blocked) {
        if ([lower containsString:item]) return YES;
    }
    return NO;
}

static BOOL SWRunCStringLooksLikeJailbreakPath(const char *path) {
    if (!path) return NO;
    return SWRunStringLooksLikeJailbreakPath([NSString stringWithUTF8String:path]);
}

static BOOL SWRunURLLooksLikeJailbreakScheme(NSURL *url) {
    NSString *scheme = [[url scheme] lowercaseString];
    if (scheme.length == 0) return NO;
    return [@[@"cydia", @"sileo", @"zbra", @"filza", @"activator", @"undecimus"] containsObject:scheme];
}

static NSArray *SWRunFilterJailbreakEntries(NSArray *items) {
    if (items.count == 0) return items;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *name = [item isKindOfClass:[NSString class]] ? item : [item description];
        if (!SWRunStringLooksLikeJailbreakPath(name)) {
            [filtered addObject:item];
        }
    }
    return filtered;
}

static BOOL SWRunReturnNO(id self, SEL _cmd) {
    return NO;
}

static BOOL SWRunReturnYES(id self, SEL _cmd) {
    return YES;
}

static NSInteger SWRunReturnZeroInteger(id self, SEL _cmd) {
    return 0;
}

static BOOL SWRunMethodReturnLooksScalar(Method method) {
    if (!method) return NO;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] == 0) return NO;
    return strchr("BcCiIsSlLqQ", type[0]) != NULL;
}

static BOOL SWRunClassShouldPatchAntiJailbreakSelectors(Class cls) {
    const char *imageName = class_getImageName(cls);
    if (!imageName) return NO;

    return strstr(imageName, "SWCampus.app/") != NULL;
}

static void SWRunPatchMethodIfExists(Class cls, SEL sel, IMP imp) {
    Method instanceMethod = class_getInstanceMethod(cls, sel);
    if (SWRunMethodReturnLooksScalar(instanceMethod)) {
        method_setImplementation(instanceMethod, imp);
    }

    Method classMethod = class_getClassMethod(cls, sel);
    if (SWRunMethodReturnLooksScalar(classMethod)) {
        method_setImplementation(classMethod, imp);
    }
}

static void SWRunPatchAntiJailbreakSelectors(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    int capacity = count;
    Class *classes = (Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return;
    int actualCount = objc_getClassList(classes, capacity);
    if (actualCount > capacity) actualCount = capacity;

    NSArray<NSString *> *boolSelectors = @[
        @"isJailBreak",
        @"isJailBroken",
        @"isJailbreak",
        @"isJailbroken",
        @"jailbreak",
        @"jailbroken",
        @"JailBreak",
        @"JailBroken",
        @"isVM"
    ];
    NSArray<NSString *> *integerSelectors = @[
        @"jailbrokenStatus",
        @"JailbrokenStatus"
    ];

    for (int i = 0; i < actualCount; i++) {
        Class cls = classes[i];
        if (!SWRunClassShouldPatchAntiJailbreakSelectors(cls)) continue;

        for (NSString *name in boolSelectors) {
            SWRunPatchMethodIfExists(cls, NSSelectorFromString(name), (IMP)SWRunReturnNO);
        }
        for (NSString *name in integerSelectors) {
            SWRunPatchMethodIfExists(cls, NSSelectorFromString(name), (IMP)SWRunReturnZeroInteger);
        }
    }
    free(classes);
}

static BOOL SWRunClassShouldPatchGPSGateSelectors(Class cls) {
    const char *className = class_getName(cls);
    if (!className) return NO;

    return strstr(className, "SWRunPrepareImpl") != NULL ||
           strstr(className, "SWFreeRunModeService") != NULL ||
           strstr(className, "SWScoreRunModeService") != NULL ||
           strstr(className, "SWSportFreeRunViewController") != NULL ||
           strstr(className, "SWSportScoreRunViewController") != NULL ||
           strstr(className, "SWOutdoorRunViewController") != NULL ||
           strstr(className, "SportStyleViewController") != NULL;
}

static void SWRunPatchGPSGateSelectors(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    int capacity = count;
    Class *classes = (Class *)calloc((size_t)capacity, sizeof(Class));
    if (!classes) return;
    int actualCount = objc_getClassList(classes, capacity);
    if (actualCount > capacity) actualCount = capacity;

    for (int i = 0; i < actualCount; i++) {
        Class cls = classes[i];
        if (!SWRunClassShouldPatchGPSGateSelectors(cls)) continue;

        SWRunPatchMethodIfExists(cls, NSSelectorFromString(@"isSignalLevelWeak"), (IMP)SWRunReturnNO);
        SWRunPatchMethodIfExists(cls, NSSelectorFromString(@"isRawGPSSignalGood"), (IMP)SWRunReturnYES);
    }
    free(classes);
}

static int SWRunCopyCStringResult(const char *value, void *oldp, size_t *oldlenp) {
    if (!value || !oldlenp) return -1;
    size_t needed = strlen(value) + 1;
    if (!oldp) {
        *oldlenp = needed;
        return 0;
    }
    if (*oldlenp < needed) {
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, value, needed);
    *oldlenp = needed;
    return 0;
}

// ============================================================
#pragma mark - Hook: NSURLSession (网络拦截)
// ============================================================

static NSString *gLastRunningURL = nil;

static BOOL SWRunShouldProcessResponse(NSData *data, NSString *requestURL, NSURLResponse *response) {
    NSString *responseURL = response.URL.absoluteString;
    return IsRunningRelatedURL(requestURL) ||
           IsRunningRelatedURL(responseURL) ||
           SWRunDataLooksPointRelated(data);
}

%hook NSURLSession

// ★ %new 必须在引用它的 hook 方法之前定义
%new
- (void)swrun_processResponseData:(NSData *)data {
    if (!data || data.length < 10) return;

    @try {
        NSError *err = nil;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data
                                                     options:0
                                                       error:&err];
        if (err || !jsonObj) return;

        NSArray<NSDictionary *> *pointsArray = ExtractPointsFromJSON(jsonObj);
        if (!pointsArray || pointsArray.count == 0) return;

        NSLog(@"[SWRunHUD] 🎯 检测到 %lu 个打卡点", (unsigned long)pointsArray.count);

        NSMutableArray<SWRunCheckpoint *> *checkpoints = [NSMutableArray array];
        for (NSDictionary *pt in pointsArray) {
            if ([pt isKindOfClass:[NSDictionary class]]) {
                SWRunCheckpoint *cp = ParseCheckpoint(pt);
                if (cp.position <= 0) cp.position = checkpoints.count + 1;
                [checkpoints addObject:cp];
                NSLog(@"[SWRunHUD]   %@", cp);
            }
        }
        if (checkpoints.count == 0) return;

        double totalDistance = 0;
        if ([jsonObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)jsonObj;
            NSDictionary *dataDict = dict[@"data"];
            if ([dataDict isKindOfClass:[NSDictionary class]]) {
                if (dataDict[@"totalDistance"]) totalDistance = [dataDict[@"totalDistance"] doubleValue];
            }
        }

        [[SWRunFloatingView sharedInstance] updateCheckpoints:checkpoints
                                                totalDistance:totalDistance];

        if (checkpoints.count >= 2) {
            [[SWRunRoutePlanner sharedInstance]
                planOptimalRouteAsync:checkpoints
                           completion:^(SWRunRoutePlan *plan) {
                NSLog(@"[SWRunHUD] %@", [plan summaryString]);
                [[SWRunFloatingView sharedInstance] updateRoutePlan:plan];
            }];
        }

    } @catch (NSException *exception) {
        NSLog(@"[SWRunHUD] ⚠️ 解析异常: %@", exception.reason);
    }
}

// ★ 拦截 dataTaskWithRequest:completionHandler:
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *urlStr = request.URL.absoluteString;
    if (IsRunningRelatedURL(urlStr)) {
        gLastRunningURL = [urlStr copy];
    }

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error && SWRunShouldProcessResponse(data, urlStr, response)) {
            [self swrun_processResponseData:data];
        }
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };

    return %orig(request, wrappedHandler);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *urlStr = url.absoluteString;
    if (IsRunningRelatedURL(urlStr)) {
        gLastRunningURL = [urlStr copy];
    }

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error && SWRunShouldProcessResponse(data, urlStr, response)) {
            [self swrun_processResponseData:data];
        }
        if (completionHandler) {
            completionHandler(data, response, error);
        }
    };

    return %orig(url, wrappedHandler);
}

%end

// ============================================================
#pragma mark - Hook: 反越狱/注入环境检测
// ============================================================

%hookf(int, access, const char *path, int mode) {
    if (SWRunCStringLooksLikeJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return %orig;
}

%hookf(int, stat, const char *path, struct stat *buf) {
    if (SWRunCStringLooksLikeJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return %orig;
}

%hookf(int, lstat, const char *path, struct stat *buf) {
    if (SWRunCStringLooksLikeJailbreakPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return %orig;
}

%hookf(FILE *, fopen, const char *path, const char *mode) {
    if (SWRunCStringLooksLikeJailbreakPath(path)) {
        errno = ENOENT;
        return NULL;
    }
    return %orig;
}

%hookf(pid_t, fork, void) {
    errno = ENOTSUP;
    return -1;
}

%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int result = %orig;
    if (result == 0 && name && namelen >= 4 && oldp &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == KERN_PROC_PID) {
#ifdef P_TRACED
        struct kinfo_proc *info = (struct kinfo_proc *)oldp;
        info->kp_proc.p_flag &= ~P_TRACED;
#endif
    }
    return result;
}

%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0)) {
        return SWRunCopyCStringResult("iPhone14,5", oldp, oldlenp);
    }
    return %orig;
}

%hookf(int, uname, struct utsname *name) {
    int result = %orig;
    if (result == 0 && name) {
        strlcpy(name->machine, "iPhone14,5", sizeof(name->machine));
    }
    return result;
}

%hookf(const char *, _dyld_get_image_name, uint32_t image_index) {
    const char *name = %orig;
    if (SWRunCStringLooksLikeJailbreakPath(name)) {
        return "/usr/lib/libobjc.A.dylib";
    }
    return name;
}

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (BOOL)isReadableFileAtPath:(NSString *)path {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (BOOL)isExecutableFileAtPath:(NSString *)path {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (BOOL)isWritableFileAtPath:(NSString *)path {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey, id> *)attr {
    if (SWRunStringLooksLikeJailbreakPath(path)) return NO;
    return %orig;
}

- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if (SWRunStringLooksLikeJailbreakPath(path)) return nil;
    return SWRunFilterJailbreakEntries(%orig);
}

%end

%hook NSProcessInfo

- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *env = %orig;
    NSMutableDictionary *clean = [env mutableCopy];
    NSArray *blockedKeys = @[@"DYLD_INSERT_LIBRARIES", @"_MSSafeMode", @"Substrate", @"Substitute", @"FRIDA"];
    for (NSString *key in blockedKeys) {
        [clean removeObjectForKey:key];
    }
    return clean;
}

- (NSArray<NSString *> *)arguments {
    return SWRunFilterJailbreakEntries(%orig);
}

%end

%hook UIDevice

- (NSString *)model {
    return @"iPhone";
}

- (NSString *)localizedModel {
    return @"iPhone";
}

- (NSString *)systemName {
    return @"iOS";
}

- (float)batteryLevel {
    return 0.82f;
}

- (UIDeviceBatteryState)batteryState {
    return UIDeviceBatteryStateUnplugged;
}

- (BOOL)isBatteryMonitoringEnabled {
    return YES;
}

%end

// ============================================================
#pragma mark - ★ GPS 模拟注入系统
// ============================================================

/// 全局状态
static BOOL        gSimActive        = NO;
static CLLocation *gSimLocation      = nil;
static CLLocation *gPreflightLocation = nil;
/// 已注册的 CLLocationManager 实例 (弱引用)
static NSHashTable *gLocationManagers = nil;
/// 记录每个 manager 的原始 delegate
static NSMapTable  *gManagerDelegates = nil;
/// 已注册的 AMapLocationManager 实例和 delegate
static NSHashTable *gAMapLocationManagers = nil;
static NSMapTable  *gAMapManagerDelegates = nil;

static void SWRunEnsureLocationContainers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLocationManagers = [NSHashTable weakObjectsHashTable];
        gManagerDelegates = [NSMapTable weakToWeakObjectsMapTable];
        gAMapLocationManagers = [NSHashTable weakObjectsHashTable];
        gAMapManagerDelegates = [NSMapTable weakToWeakObjectsMapTable];
    });
}

static CLLocationSourceInformation *SWRunFakeLocationSourceInfo(void) {
    if (@available(iOS 15.0, *)) {
        return [[CLLocationSourceInformation alloc] initWithSoftwareSimulationState:NO
                                                        andExternalAccessoryState:NO];
    }
    return nil;
}

static BOOL SWRunCoordinateLooksUsable(CLLocationCoordinate2D coordinate) {
    if (!CLLocationCoordinate2DIsValid(coordinate)) return NO;
    return fabs(coordinate.latitude) > 0.000001 && fabs(coordinate.longitude) > 0.000001;
}

static CLLocation *SWRunBuildStrongGPSLocation(CLLocation *loc) {
    if (!loc || !SWRunCoordinateLooksUsable(loc.coordinate)) return nil;

    CLLocationDistance altitude = loc.verticalAccuracy >= 0 ? loc.altitude : 30.0;
    CLLocationDirection course = loc.course >= 0 ? loc.course : 0.0;
    CLLocationSpeed speed = loc.speed >= 0 ? loc.speed : 0.8;
    NSDate *timestamp = loc.timestamp ?: [NSDate date];

    if (@available(iOS 13.4, *)) {
        return [[CLLocation alloc] initWithCoordinate:loc.coordinate
                                             altitude:altitude
                                   horizontalAccuracy:4.0
                                     verticalAccuracy:3.0
                                               course:course
                                       courseAccuracy:3.0
                                                speed:speed
                                        speedAccuracy:0.3
                                            timestamp:timestamp];
    }

    return [[CLLocation alloc] initWithCoordinate:loc.coordinate
                                         altitude:altitude
                               horizontalAccuracy:4.0
                                 verticalAccuracy:3.0
                                           course:course
                                            speed:speed
                                        timestamp:timestamp];
}

static void SWRunRememberPreflightLocation(CLLocation *loc) {
    CLLocation *strongLoc = SWRunBuildStrongGPSLocation(loc);
    if (strongLoc) {
        gPreflightLocation = strongLoc;
    }
}

static NSArray<CLLocation *> *SWRunBuildStrongGPSLocations(NSArray<CLLocation *> *locations) {
    if (locations.count == 0) return locations;

    NSMutableArray<CLLocation *> *strongLocations = [NSMutableArray arrayWithCapacity:locations.count];
    for (CLLocation *loc in locations) {
        CLLocation *strongLoc = SWRunBuildStrongGPSLocation(loc);
        if (strongLoc) {
            [strongLocations addObject:strongLoc];
            gPreflightLocation = strongLoc;
        } else if (loc) {
            [strongLocations addObject:loc];
        }
    }
    return strongLocations.count > 0 ? strongLocations : locations;
}

static CLHeading *SWRunBuildFakeHeading(void) {
    SWSimulatedMotionData *md = [SWRunSimulator sharedInstance].motionData;
    CLHeading *fakeHeading = [[CLHeading alloc] init];
    @try {
        [fakeHeading setValue:@(md.currentHeading)      forKey:@"magneticHeading"];
        [fakeHeading setValue:@(md.currentHeading)       forKey:@"trueHeading"];
        [fakeHeading setValue:@(md.headingAccuracy)      forKey:@"headingAccuracy"];
        [fakeHeading setValue:@(md.currentHeading - 3.5) forKey:@"x"];
        [fakeHeading setValue:@(0)                       forKey:@"y"];
        [fakeHeading setValue:@(0)                       forKey:@"z"];
        [fakeHeading setValue:[NSDate date]              forKey:@"timestamp"];
    } @catch (NSException *e) {}
    return fakeHeading;
}

static void SWRunDeliverLocationToDelegates(CLLocation *loc) {
    if (!loc) return;
    SWRunEnsureLocationContainers();

    CLLocation *deliveredLoc = SWRunBuildStrongGPSLocation(loc) ?: loc;
    NSArray *locations = @[deliveredLoc];
    for (CLLocationManager *mgr in gLocationManagers) {
        id delegate = [gManagerDelegates objectForKey:mgr];
        if (delegate && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:mgr didUpdateLocations:locations];
        }
    }

    SEL amapUpdateSel = NSSelectorFromString(@"amapLocationManager:didUpdateLocation:");
    for (id mgr in gAMapLocationManagers) {
        id delegate = [gAMapManagerDelegates objectForKey:mgr];
        if (delegate && [delegate respondsToSelector:amapUpdateSel]) {
            ((void(*)(id, SEL, id, CLLocation *))objc_msgSend)(delegate, amapUpdateSel, mgr, deliveredLoc);
        }
    }
}

static void SWRunDeliverHeadingToDelegates(void) {
    SWRunEnsureLocationContainers();
    CLHeading *heading = SWRunBuildFakeHeading();
    for (CLLocationManager *mgr in gLocationManagers) {
        id delegate = [gManagerDelegates objectForKey:mgr];
        if (delegate && [delegate respondsToSelector:@selector(locationManager:didUpdateHeading:)]) {
            [delegate locationManager:mgr didUpdateHeading:heading];
        }
    }
}

void SWRunStopGPSSimulation(void);

/// 启动GPS模拟 — 由浮动窗按钮触发
void SWRunStartGPSSimulation(void) {
    if (gSimActive) return;

    // 获取当前路线规划
    SWRunFloatingView *hud = [SWRunFloatingView sharedInstance];
    SWRunRoutePlan *plan = [hud valueForKey:@"currentPlan"];

    if (!plan || plan.optimalOrder.count < 2) {
        NSLog(@"[SWRunHUD] ❌ 没有路线规划, 无法模拟");
        return;
    }

    [[SWRunSimulator sharedInstance]
        startSimulationWithCheckpoints:[hud valueForKey:@"checkpoints"]
                          visitOrder:plan.optimalOrder
                     onTick:^(CLLocation *loc, NSInteger step) {
        gSimLocation = SWRunBuildStrongGPSLocation(loc) ?: loc;
        gSimActive = YES;

        // ★ 更新悬浮窗状态标签
        SWRunSimulator *sim = [SWRunSimulator sharedInstance];
        SWSimulatedMotionData *md = sim.motionData;
        NSString *status = [NSString stringWithFormat:
            @"🚶 模拟 | %.0f/%.0fm | 👣%ld步 | 🏃%.0f步/分 | 🏢%ld层 | 🏔%.0fm | ➡P%ld",
            sim.traveledDistance, sim.totalPathDistance,
            (long)md.numberOfSteps,
            md.currentCadence * 60.0,
            (long)md.floorsAscended,
            md.currentAltitude,
            (long)(sim.currentTargetIndex + 1)];
        dispatch_async(dispatch_get_main_queue(), ^{
            UILabel *label = [hud valueForKey:@"simStatusLabel"];
            if (label) {
                label.text = status;
                label.hidden = NO;
            }
        });

        // 将同一个模拟快照发送给 CoreLocation / AMap delegates
        SWRunDeliverLocationToDelegates(gSimLocation);
        SWRunDeliverHeadingToDelegates();

        // 广播通知
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"SWRunSimulatedLocationUpdate"
                          object:nil
                        userInfo:@{@"location": gSimLocation ?: loc}];
    }
    onComplete:^(BOOL finished) {
        gSimActive = NO;
        gSimLocation = nil;
        SWRunStopGPSSimulation();
        NSLog(@"[SWRunHUD] %@", finished ? @"✅ GPS模拟完成" : @"❌ GPS模拟异常终止");
    }];

    // 更新悬浮窗状态
    [hud setSimulationRunning:YES];
}

/// 停止GPS模拟
void SWRunStopGPSSimulation(void) {
    [[SWRunSimulator sharedInstance] stop];
    gSimActive = NO;
    gSimLocation = nil;
    [[SWRunFloatingView sharedInstance] setSimulationRunning:NO];
}

/// 暂停/继续切换
void SWRunToggleSimulation(void) {
    SWRunSimulator *sim = [SWRunSimulator sharedInstance];
    if (sim.state == SWSimulatorStateRunning) {
        [sim pause];
        [[SWRunFloatingView sharedInstance] setSimulationRunning:NO];
    } else if (sim.state == SWSimulatorStatePaused) {
        [sim resume];
        [[SWRunFloatingView sharedInstance] setSimulationRunning:YES];
    }
}

// ============================================================
#pragma mark - Hook: CLLocationManager (注入模拟GPS)
// ============================================================

%hook CLLocationManager

+ (BOOL)locationServicesEnabled {
    return YES;
}

+ (CLAuthorizationStatus)authorizationStatus {
    return kCLAuthorizationStatusAuthorizedAlways;
}

- (CLAuthorizationStatus)authorizationStatus {
    return kCLAuthorizationStatusAuthorizedAlways;
}

- (void)setDelegate:(id)delegate {
    %orig;

    SWRunEnsureLocationContainers();
    [gLocationManagers addObject:self];
    if (delegate) {
        [gManagerDelegates setObject:delegate forKey:self];
    }
}

- (CLLocation *)location {
    if (gSimActive && gSimLocation) {
        return gSimLocation;
    }

    CLLocation *loc = %orig;
    SWRunRememberPreflightLocation(loc);
    return gPreflightLocation ?: loc;
}

- (void)startUpdatingLocation {
    if (gSimActive) {
        // 模拟模式: 仍然调用原始方法以维持内部状态
        // 但实际位置由 SWRunSimulator 通过 delegate 回调注入
        NSLog(@"[SWRunHUD] 📍 startUpdatingLocation → GPS模拟已接管");
        SWRunDeliverLocationToDelegates(gSimLocation);
    }
    %orig;

    if (!gSimActive && gPreflightLocation) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            SWRunDeliverLocationToDelegates(gPreflightLocation);
        });
    }
}

- (void)requestLocation {
    if (gSimActive && gSimLocation) {
        // 单次定位请求 → 直接返回模拟位置
        SWRunDeliverLocationToDelegates(gSimLocation);
        return;
    }
    if (gPreflightLocation) {
        SWRunDeliverLocationToDelegates(gPreflightLocation);
    }
    %orig;
}

- (void)startMonitoringSignificantLocationChanges {
    if (gSimActive && gSimLocation) {
        NSLog(@"[SWRunHUD] 📍 显著位置变化监听 → GPS模拟已接管");
        SWRunDeliverLocationToDelegates(gSimLocation);
    }
    %orig;
}

- (void)startMonitoringForRegion:(CLRegion *)region {
    if (gSimActive && region) {
        id delegate = [gManagerDelegates objectForKey:self];
        if (delegate && [delegate respondsToSelector:@selector(locationManager:didDetermineState:forRegion:)]) {
            [delegate locationManager:self didDetermineState:CLRegionStateInside forRegion:region];
        }
    }
    %orig;
}

%end

%hook CLLocation

- (CLLocationCoordinate2D)coordinate {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.coordinate;
    return %orig;
}

- (CLLocationDistance)altitude {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.altitude;
    return %orig;
}

- (CLLocationAccuracy)horizontalAccuracy {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.horizontalAccuracy;
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 4.0);
}

- (CLLocationAccuracy)verticalAccuracy {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.verticalAccuracy;
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 3.0);
}

- (CLLocationDirection)course {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.course;
    return %orig;
}

- (CLLocationSpeed)speed {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.speed;
    return %orig;
}

- (NSDate *)timestamp {
    if (gSimActive && gSimLocation && self != gSimLocation) return gSimLocation.timestamp;
    return %orig;
}

- (CLLocationAccuracy)speedAccuracy {
    if (gSimActive && gSimLocation) return 0.3;
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 0.3);
}

- (CLLocationDirectionAccuracy)courseAccuracy {
    if (gSimActive && gSimLocation) return [SWRunSimulator sharedInstance].motionData.headingAccuracy;
    CLLocationDirectionAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 3.0);
}

- (CLLocationSourceInformation *)sourceInformation {
    CLLocationSourceInformation *sourceInfo = %orig;
    return sourceInfo ?: SWRunFakeLocationSourceInfo();
}

%end

%hook CLLocationSourceInformation

- (BOOL)isSimulatedBySoftware {
    return NO;
}

- (BOOL)isProducedByAccessory {
    return NO;
}

%end

// ============================================================
#pragma mark - Hook: CMPedometer (模拟步数/距离/步频/爬楼)
// ============================================================

/// 缓存的模拟计步器数据 (从 SWRunSimulator.motionData 获取)
static CMPedometerData *gFakePedometerData = nil;

/// 生成一个假的 CMPedometerData
static CMPedometerData *BuildFakePedometerData(NSDate *startDate, NSDate *endDate) {
    SWRunSimulator *sim = [SWRunSimulator sharedInstance];
    if (sim.state != SWSimulatorStateRunning && sim.state != SWSimulatorStatePaused) {
        return gFakePedometerData;
    }

    SWSimulatedMotionData *md = sim.motionData;
    if (!md) return gFakePedometerData;

    // 用动态 API 创建 CMPedometerData (因为 init 是私有的)
    // 使用 KVC 或创建子类来注入数据

    // 实际实现: 创建一个假的数据对象
    // CMPedometerData 是不可变的, 我们用 objc 运行时动态构建

    Class pedoClass = NSClassFromString(@"CMPedometerData");
    if (!pedoClass) return gFakePedometerData;

    id fakeData = [[pedoClass alloc] init];
    if (!fakeData) return gFakePedometerData;

    // 使用 KVC 设置属性 (CMPedometerData 内部属性是私有的)
    @try {
        [fakeData setValue:@(md.numberOfSteps)     forKey:@"numberOfSteps"];
        [fakeData setValue:@(md.distance)           forKey:@"distance"];
        [fakeData setValue:(startDate ?: sim.simulationStartDate ?: [NSDate date]) forKey:@"startDate"];
        [fakeData setValue:(endDate ?: [NSDate date]) forKey:@"endDate"];
        [fakeData setValue:@(md.averageActivePace)  forKey:@"averageActivePace"];
        [fakeData setValue:@(md.currentPace)        forKey:@"currentPace"];
        [fakeData setValue:@(md.currentCadence)     forKey:@"currentCadence"];
        [fakeData setValue:@(md.floorsAscended)     forKey:@"floorsAscended"];
        [fakeData setValue:@(md.floorsDescended)    forKey:@"floorsDescended"];
    } @catch (NSException *e) {
        // KVC 失败则返回缓存
    }

    gFakePedometerData = fakeData;
    return fakeData;
}

%hook CMPedometer

+ (BOOL)isStepCountingAvailable {
    return YES;
}

+ (BOOL)isDistanceAvailable {
    return YES;
}

+ (BOOL)isPaceAvailable {
    return YES; // iOS 9+
}

+ (BOOL)isCadenceAvailable {
    return YES; // iOS 10+
}

+ (BOOL)isFloorCountingAvailable {
    return YES; // iOS 8+
}

// ★ 核心: 拦截实时计步器更新
- (void)startPedometerUpdatesFromDate:(NSDate *)start
                          withHandler:(CMPedometerHandler)handler {
    if (!handler) {
        %orig;
        return;
    }

    if (gSimActive) {
        // 模拟模式: 存储 original handler, 由 tick 驱动
        // 但我们无法在 %orig 之前知道 handler 内容
        // 方案: 包装 handler
        CMPedometerHandler wrappedHandler = ^(CMPedometerData *data, NSError *error) {
            if (gSimActive) {
                CMPedometerData *fakeData = BuildFakePedometerData(start, [NSDate date]);
                if (fakeData) {
                    handler(fakeData, nil);
                } else {
                    handler(data, error);
                }
            } else {
                handler(data, error);
            }
        };
        %orig(start, wrappedHandler);
    } else {
        %orig;
    }
}

// ★ 查询历史计步数据 → 返回模拟数据
- (void)queryPedometerDataFromDate:(NSDate *)start
                            toDate:(NSDate *)end
                       withHandler:(CMPedometerHandler)handler {
    if (!handler) { %orig; return; }

    if (gSimActive) {
        CMPedometerData *fakeData = BuildFakePedometerData(start, end);
        if (fakeData) {
            handler(fakeData, nil);
            return;
        }
    }
    %orig;
}

%end

%hook CMPedometerData

- (NSNumber *)numberOfSteps {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.numberOfSteps);
    return %orig;
}

- (NSNumber *)distance {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.distance);
    return %orig;
}

- (NSDate *)startDate {
    if (gSimActive) {
        NSDate *start = [SWRunSimulator sharedInstance].simulationStartDate;
        if (start) return start;
    }
    return %orig;
}

- (NSDate *)endDate {
    if (gSimActive) return [NSDate date];
    return %orig;
}

- (NSNumber *)averageActivePace {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.averageActivePace);
    return %orig;
}

- (NSNumber *)currentPace {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.currentPace);
    return %orig;
}

- (NSNumber *)currentCadence {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.currentCadence);
    return %orig;
}

- (NSNumber *)floorsAscended {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.floorsAscended);
    return %orig;
}

- (NSNumber *)floorsDescended {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.floorsDescended);
    return %orig;
}

%end

static double SWRunMotionPhase(void) {
    SWRunSimulator *sim = [SWRunSimulator sharedInstance];
    double cadence = MAX(sim.motionData.currentCadence, 1.0);
    return sim.elapsedSeconds * cadence * M_PI;
}

static CMAcceleration SWRunFakeUserAcceleration(void) {
    double phase = SWRunMotionPhase();
    CMAcceleration a;
    a.x = 0.035 * sin(phase);
    a.y = 0.045 * fabs(sin(phase * 0.5));
    a.z = 0.025 * cos(phase);
    return a;
}

static CMAcceleration SWRunFakeGravity(void) {
    CMAcceleration g;
    g.x = 0.01 * sin(SWRunMotionPhase() * 0.25);
    g.y = 0.02 * cos(SWRunMotionPhase() * 0.25);
    g.z = -1.0;
    return g;
}

static CMAcceleration SWRunFakeAccelerometer(void) {
    CMAcceleration user = SWRunFakeUserAcceleration();
    CMAcceleration gravity = SWRunFakeGravity();
    CMAcceleration a;
    a.x = user.x + gravity.x;
    a.y = user.y + gravity.y;
    a.z = user.z + gravity.z;
    return a;
}

static CMRotationRate SWRunFakeRotationRate(void) {
    double phase = SWRunMotionPhase();
    CMRotationRate r;
    r.x = 0.015 * sin(phase);
    r.y = 0.010 * cos(phase * 0.7);
    r.z = 0.020 * sin(phase * 0.5);
    return r;
}

static CMMotionActivity *SWRunBuildFakeActivity(void) {
    CMMotionActivity *activity = [[CMMotionActivity alloc] init];
    @try {
        [activity setValue:@(NO) forKey:@"stationary"];
        [activity setValue:@(YES) forKey:@"walking"];
        [activity setValue:@(NO) forKey:@"running"];
        [activity setValue:@(NO) forKey:@"automotive"];
        [activity setValue:@(NO) forKey:@"cycling"];
        [activity setValue:@(CMMotionActivityConfidenceHigh) forKey:@"confidence"];
        [activity setValue:([SWRunSimulator sharedInstance].simulationStartDate ?: [NSDate date]) forKey:@"startDate"];
    } @catch (NSException *e) {}
    return activity;
}

static CMAccelerometerData *SWRunBuildFakeAccelerometerData(void) {
    Class cls = NSClassFromString(@"CMAccelerometerData");
    return cls ? [[cls alloc] init] : nil;
}

static CMGyroData *SWRunBuildFakeGyroData(void) {
    Class cls = NSClassFromString(@"CMGyroData");
    return cls ? [[cls alloc] init] : nil;
}

static CMDeviceMotion *SWRunBuildFakeDeviceMotion(void) {
    Class cls = NSClassFromString(@"CMDeviceMotion");
    return cls ? [[cls alloc] init] : nil;
}

%hook CMMotionManager

- (BOOL)isAccelerometerAvailable {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)isGyroAvailable {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)isDeviceMotionAvailable {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)isAccelerometerActive {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)isGyroActive {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)isDeviceMotionActive {
    if (gSimActive) return YES;
    return %orig;
}

- (CMAccelerometerData *)accelerometerData {
    if (gSimActive) return SWRunBuildFakeAccelerometerData();
    return %orig;
}

- (CMGyroData *)gyroData {
    if (gSimActive) return SWRunBuildFakeGyroData();
    return %orig;
}

- (CMDeviceMotion *)deviceMotion {
    if (gSimActive) return SWRunBuildFakeDeviceMotion();
    return %orig;
}

- (void)startAccelerometerUpdates {
    if (gSimActive) NSLog(@"[SWRunHUD] CMMotionManager accelerometer -> 模拟数据已接管");
    %orig;
}

- (void)startGyroUpdates {
    if (gSimActive) NSLog(@"[SWRunHUD] CMMotionManager gyro -> 模拟数据已接管");
    %orig;
}

- (void)startDeviceMotionUpdates {
    if (gSimActive) NSLog(@"[SWRunHUD] CMMotionManager deviceMotion -> 模拟数据已接管");
    %orig;
}

- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue
                             withHandler:(CMAccelerometerHandler)handler {
    if (gSimActive && handler) {
        CMAccelerometerHandler wrapped = ^(CMAccelerometerData *data, NSError *error) {
            handler(data, nil);
        };
        %orig(queue, wrapped);
        return;
    }
    %orig;
}

- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue
                    withHandler:(CMGyroHandler)handler {
    if (gSimActive && handler) {
        CMGyroHandler wrapped = ^(CMGyroData *data, NSError *error) {
            handler(data, nil);
        };
        %orig(queue, wrapped);
        return;
    }
    %orig;
}

- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMDeviceMotionHandler)handler {
    if (gSimActive && handler) {
        CMDeviceMotionHandler wrapped = ^(CMDeviceMotion *motion, NSError *error) {
            handler(motion, nil);
        };
        %orig(queue, wrapped);
        return;
    }
    %orig;
}

%end

%hook CMAccelerometerData

- (CMAcceleration)acceleration {
    if (gSimActive) return SWRunFakeAccelerometer();
    return %orig;
}

%end

%hook CMGyroData

- (CMRotationRate)rotationRate {
    if (gSimActive) return SWRunFakeRotationRate();
    return %orig;
}

%end

%hook CMDeviceMotion

- (CMAcceleration)userAcceleration {
    if (gSimActive) return SWRunFakeUserAcceleration();
    return %orig;
}

- (CMAcceleration)gravity {
    if (gSimActive) return SWRunFakeGravity();
    return %orig;
}

- (CMRotationRate)rotationRate {
    if (gSimActive) return SWRunFakeRotationRate();
    return %orig;
}

%end

// ============================================================
#pragma mark - Hook: CMMotionActivityManager (报告"正在步行")
// ============================================================

%hook CMMotionActivityManager

+ (BOOL)isActivityAvailable {
    return YES;
}

- (void)startActivityUpdatesToQueue:(NSOperationQueue *)queue
                        withHandler:(CMMotionActivityHandler)handler {
    if (!handler) { %orig; return; }

    if (gSimActive) {
        // 创建一个假的 walking activity
        NSOperationQueue *targetQueue = queue ?: [NSOperationQueue mainQueue];
        [targetQueue addOperationWithBlock:^{
            handler(SWRunBuildFakeActivity());
        }];

        CMMotionActivityHandler wrappedHandler = ^(CMMotionActivity *activity) {
            if (gSimActive) {
                // 尝试用 KVC 构造 walking 的 activity
                @try {
                    [activity setValue:@(YES) forKey:@"walking"];
                    [activity setValue:@(0.95) forKey:@"confidence"];
                    [activity setValue:@(NO)  forKey:@"running"];
                    [activity setValue:@(NO)  forKey:@"automotive"];
                    [activity setValue:@(NO)  forKey:@"cycling"];
                    [activity setValue:@(NO)  forKey:@"stationary"];
                    [activity setValue:[NSDate date] forKey:@"startDate"];
                } @catch (NSException *e) {}
                handler(activity);
            } else {
                handler(activity);
            }
        };
        %orig(queue, wrappedHandler);
    } else {
        %orig;
    }
}

- (void)queryActivityStartingFromDate:(NSDate *)start
                               toDate:(NSDate *)end
                              toQueue:(NSOperationQueue *)queue
                          withHandler:(CMMotionActivityQueryHandler)handler {
    if (!handler) { %orig; return; }

    if (gSimActive) {
        NSOperationQueue *targetQueue = queue ?: [NSOperationQueue mainQueue];
        [targetQueue addOperationWithBlock:^{
            handler(@[SWRunBuildFakeActivity()], nil);
        }];
        return;
    }
    %orig;
}

%end

%hook CMMotionActivity

- (BOOL)stationary {
    if (gSimActive) return NO;
    return %orig;
}

- (BOOL)walking {
    if (gSimActive) return YES;
    return %orig;
}

- (BOOL)running {
    if (gSimActive) return NO;
    return %orig;
}

- (BOOL)automotive {
    if (gSimActive) return NO;
    return %orig;
}

- (BOOL)cycling {
    if (gSimActive) return NO;
    return %orig;
}

- (CMMotionActivityConfidence)confidence {
    if (gSimActive) return CMMotionActivityConfidenceHigh;
    return %orig;
}

- (NSDate *)startDate {
    if (gSimActive) return [SWRunSimulator sharedInstance].simulationStartDate ?: [NSDate date];
    return %orig;
}

%end

// ============================================================
#pragma mark - Hook: CMAltimeter (模拟气压高度计)
// ============================================================

%hook CMAltimeter

+ (BOOL)isRelativeAltitudeAvailable {
    return YES;
}

- (void)startRelativeAltitudeUpdatesToQueue:(NSOperationQueue *)queue
                                 withHandler:(CMAltitudeHandler)handler {
    if (!handler) { %orig; return; }

    if (gSimActive) {
        CMAltitudeHandler wrappedHandler = ^(CMAltitudeData *data, NSError *error) {
            if (gSimActive) {
                SWSimulatedMotionData *md = [SWRunSimulator sharedInstance].motionData;
                @try {
                    [data setValue:@(md.relativeAltitude) forKey:@"relativeAltitude"];
                    [data setValue:@(md.currentPressure)   forKey:@"pressure"];
                } @catch (NSException *e) {}
                handler(data, nil);
            } else {
                handler(data, error);
            }
        };
        %orig(queue, wrappedHandler);
    } else {
        %orig;
    }
}

%end

%hook CMAltitudeData

- (NSNumber *)relativeAltitude {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.relativeAltitude);
    return %orig;
}

- (NSNumber *)pressure {
    if (gSimActive) return @([SWRunSimulator sharedInstance].motionData.currentPressure);
    return %orig;
}

%end

// ============================================================
#pragma mark - Hook: CLHeading / CLLocationManager (磁力罗盘)
// ============================================================

%hook CLLocationManager

- (void)startUpdatingHeading {
    if (gSimActive) {
        NSLog(@"[SWRunHUD] 🧭 startUpdatingHeading -> 模拟磁力计");
    }
    %orig;
}

- (CLHeading *)heading {
    if (gSimActive) {
        SWSimulatedMotionData *md = [SWRunSimulator sharedInstance].motionData;
        CLHeading *fakeHeading = [[CLHeading alloc] init];
        @try {
            [fakeHeading setValue:@(md.currentHeading)      forKey:@"magneticHeading"];
            [fakeHeading setValue:@(md.currentHeading)       forKey:@"trueHeading"];
            [fakeHeading setValue:@(md.headingAccuracy)      forKey:@"headingAccuracy"];
            [fakeHeading setValue:@(md.currentHeading - 3.5) forKey:@"x"];
            [fakeHeading setValue:@(0)                       forKey:@"y"];
            [fakeHeading setValue:@(0)                       forKey:@"z"];
            [fakeHeading setValue:[NSDate date]              forKey:@"timestamp"];
        } @catch (NSException *e) {}
        return fakeHeading;
    }
    return %orig;
}

%end

%hook CLHeading

- (CLLocationDirection)magneticHeading {
    if (gSimActive) return [SWRunSimulator sharedInstance].motionData.currentHeading;
    return %orig;
}

- (CLLocationDirection)trueHeading {
    if (gSimActive) return [SWRunSimulator sharedInstance].motionData.currentHeading;
    return %orig;
}

- (CLLocationDirection)headingAccuracy {
    if (gSimActive) return [SWRunSimulator sharedInstance].motionData.headingAccuracy;
    return %orig;
}

- (CLHeadingComponentValue)x {
    if (gSimActive) return [SWRunSimulator sharedInstance].motionData.currentHeading - 3.5;
    return %orig;
}

- (CLHeadingComponentValue)y {
    if (gSimActive) return 0;
    return %orig;
}

- (CLHeadingComponentValue)z {
    if (gSimActive) return 0;
    return %orig;
}

- (NSDate *)timestamp {
    if (gSimActive) return [NSDate date];
    return %orig;
}

%end

// ============================================================
#pragma mark - Hook: BMKLocationManager (百度定位SDK) + 回调注入
// ============================================================

%hook BMKLocationManager

- (void)startUpdatingLocation {
    if (gSimActive) {
        NSLog(@"[SWRunHUD] BMKLocationManager -> GPS模拟已接管(百度SDK)");
    }
    %orig;
}

%end

// ============================================================
#pragma mark - Hook: AMapLocationManager (高德定位SDK)
// ============================================================

%hook AMapLocationManager

- (void)setDelegate:(id)delegate {
    %orig;
    SWRunEnsureLocationContainers();
    [gAMapLocationManagers addObject:self];
    if (delegate) {
        [gAMapManagerDelegates setObject:delegate forKey:self];
    }
}

- (void)setDelegate:(id)delegate delegateQueue:(id)delegateQueue {
    %orig;
    SWRunEnsureLocationContainers();
    [gAMapLocationManagers addObject:self];
    if (delegate) {
        [gAMapManagerDelegates setObject:delegate forKey:self];
    }
}

- (void)startUpdatingLocation {
    if (gSimActive && gSimLocation) {
        NSLog(@"[SWRunHUD] AMapLocationManager -> GPS模拟已接管(高德SDK)");
        SWRunDeliverLocationToDelegates(gSimLocation);
    }
    %orig;
}

- (void)requestLocationWithReGeocode:(BOOL)withReGeocode
                     completionBlock:(void (^)(CLLocation *location, id regeocode, NSError *error))completionBlock {
    if (gSimActive && gSimLocation && completionBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(gSimLocation, nil, nil);
        });
        return;
    }

    if (completionBlock) {
        void (^wrappedBlock)(CLLocation *, id, NSError *) = ^(CLLocation *location, id regeocode, NSError *error) {
            CLLocation *strongLocation = SWRunBuildStrongGPSLocation(location);
            if (strongLocation) {
                gPreflightLocation = strongLocation;
                completionBlock(strongLocation, regeocode, nil);
            } else {
                completionBlock(location, regeocode, error);
            }
        };
        %orig(withReGeocode, wrappedBlock);
        return;
    }
    %orig;
}

%end

%hook MAMapView

- (id)userLocation {
    id userLocation = %orig;
    if (gSimActive && gSimLocation && userLocation) {
        @try {
            [userLocation setValue:gSimLocation forKey:@"location"];
        } @catch (NSException *e) {}
    }
    return userLocation;
}

- (CLLocationCoordinate2D)centerCoordinate {
    if (gSimActive && gSimLocation) return gSimLocation.coordinate;
    return %orig;
}

%end

// 拦截百度定位 delegate 回调
%hook NSObject
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (gSimActive && gSimLocation) {
        %orig(manager, @[gSimLocation]);
        return;
    }

    NSArray<CLLocation *> *strongLocations = SWRunBuildStrongGPSLocations(locations);
    %orig(manager, strongLocations);
}

- (void)locationManager:(CLLocationManager *)manager didUpdateHeading:(CLHeading *)newHeading {
    if (gSimActive) {
        %orig(manager, SWRunBuildFakeHeading());
        return;
    }
    %orig;
}

- (void)locationManager:(CLLocationManager *)manager
    didUpdateToLocation:(CLLocation *)newLocation
           fromLocation:(CLLocation *)oldLocation {
    if (gSimActive && gSimLocation) {
        %orig(manager, gSimLocation, oldLocation ?: gSimLocation);
        return;
    }

    CLLocation *strongNewLocation = SWRunBuildStrongGPSLocation(newLocation);
    CLLocation *strongOldLocation = SWRunBuildStrongGPSLocation(oldLocation);
    if (strongNewLocation) {
        gPreflightLocation = strongNewLocation;
        %orig(manager, strongNewLocation, strongOldLocation ?: oldLocation ?: strongNewLocation);
        return;
    }
    %orig;
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (gSimActive && gSimLocation) {
        return;
    }
    %orig;
}

- (void)locationManager:(CLLocationManager *)manager
monitoringDidFailForRegion:(CLRegion *)region
              withError:(NSError *)error {
    if (gSimActive && gSimLocation) {
        return;
    }
    %orig;
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    %orig(manager, kCLAuthorizationStatusAuthorizedAlways);
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    %orig;
}

- (void)BMKLocationManager:(id)manager
         didUpdateLocation:(id)bmkLocation
                   orError:(NSError *)error {
    if (gSimActive && gSimLocation) {
        @try {
            if ([bmkLocation respondsToSelector:@selector(location)]) {
                [bmkLocation setValue:gSimLocation forKey:@"location"];
            }
        } @catch (NSException *e) {}
    }
    %orig;
}

- (void)amapLocationManager:(id)manager didUpdateLocation:(CLLocation *)location {
    if (gSimActive && gSimLocation) {
        %orig(manager, gSimLocation);
        return;
    }

    CLLocation *strongLocation = SWRunBuildStrongGPSLocation(location);
    if (strongLocation) {
        gPreflightLocation = strongLocation;
        %orig(manager, strongLocation);
        return;
    }
    %orig;
}

- (void)amapLocationManager:(id)manager didUpdateLocation:(CLLocation *)location reGeocode:(id)reGeocode {
    if (gSimActive && gSimLocation) {
        %orig(manager, gSimLocation, reGeocode);
        return;
    }

    CLLocation *strongLocation = SWRunBuildStrongGPSLocation(location);
    if (strongLocation) {
        gPreflightLocation = strongLocation;
        %orig(manager, strongLocation, reGeocode);
        return;
    }
    %orig;
}

- (void)amapLocationManager:(id)manager didFailWithError:(NSError *)error {
    if (gSimActive && gSimLocation) {
        return;
    }
    %orig;
}

- (void)mapView:(id)mapView didUpdateUserLocation:(id)userLocation updatingLocation:(BOOL)updatingLocation {
    if (gSimActive && gSimLocation && userLocation) {
        @try {
            [userLocation setValue:gSimLocation forKey:@"location"];
        } @catch (NSException *e) {}
        %orig(mapView, userLocation, updatingLocation);
        return;
    }
    %orig;
}

%end

// ============================================================
#pragma mark - Hook: UIApplication (确保悬浮窗初始化)
// ============================================================

static BOOL gHUDInitialized = NO;

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (SWRunURLLooksLikeJailbreakScheme(url)) return NO;
    return %orig;
}

- (void)sendEvent:(UIEvent *)event {
    %orig;

    // 延迟初始化悬浮窗（等待 App 完全加载）
    if (!gHUDInitialized) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // 延迟0.5秒确保UI就绪
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                          dispatch_get_main_queue(), ^{
                gHUDInitialized = YES;
                [[SWRunFloatingView sharedInstance] showCollapsed];
                SWRunPatchAntiJailbreakSelectors();
                SWRunPatchGPSGateSelectors();
                NSLog(@"[SWRunHUD] ✅ 悬浮窗系统初始化完成");
                NSLog(@"[SWRunHUD] 📱 运动世界 校园跑点位监控已激活");
                NSLog(@"[SWRunHUD] 🔴 必经点(isFixed=1) 将显示为红色");
                NSLog(@"[SWRunHUD] 🔵 普通点(isFixed=0) 将显示为蓝色");
                NSLog(@"[SWRunHUD] 👆 点击悬浮球展开, 拖拽移动, 5秒自动收起");
            });
        });
    }
}

%end

// ============================================================
#pragma mark - Hook: 主ViewController (检测跑步页面)
// ============================================================

// 通过 Runtime 动态查找跑步相关的 ViewController
// 常见的类名模式: SWRunning*, SWRun*, SWSport*, SWIndoorRunning*

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    SWRunPatchGPSGateSelectors();

    NSString *className = NSStringFromClass([self class]);

    // 检测是否进入跑步页面
    if ([className hasPrefix:@"SWRun"] ||
        [className hasPrefix:@"SWSport"] ||
        [className hasPrefix:@"SWIndoor"] ||
        [className containsString:@"Running"] ||
        [className containsString:@"Run"]) {

        NSLog(@"[SWRunHUD] 🏃 进入跑步页面: %@", className);

        // 确保悬浮窗可用
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            [[SWRunFloatingView sharedInstance] showCollapsed];
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    if ([className hasPrefix:@"SWRun"] ||
        [className hasPrefix:@"SWSport"] ||
        [className hasPrefix:@"SWIndoor"]) {

        // 可选: 离开跑步页面时隐藏悬浮窗
        // [[SWRunFloatingView sharedInstance] hide];
    }
}

%end

// ============================================================
#pragma mark - 构造函数
// ============================================================

%ctor {
    NSLog(@"[SWRunHUD] 🚀 SWRunCheckpointHUD v1.0 已加载");
    NSLog(@"[SWRunHUD] 🎯 目标App: com.wanhang.school (运动世界)");
    NSLog(@"[SWRunHUD] 📋 功能: 实时显示跑步必经点位/普通点位");
    NSLog(@"[SWRunHUD] 🔌 注入方式: Dopamine rootless + libsubstitute");

    NSLog(@"[SWRunHUD] 🛡 反越狱检测入口将延迟到 App 激活后接管");

    // 注册通知：App 进入前台时重新显示悬浮窗
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        // 确保悬浮窗可以在前台显示
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            // 重新激活 overlay window
            [[SWRunFloatingView sharedInstance] showCollapsed];
            SWRunPatchAntiJailbreakSelectors();
            SWRunPatchGPSGateSelectors();
            NSLog(@"[SWRunHUD] 🔄 App 进入前台, 悬浮球已显示");
        });
    }];

    NSLog(@"[SWRunHUD] ✅ 所有 Hooks 安装完毕");
}
