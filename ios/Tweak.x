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
#import <MapKit/MapKit.h>
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
#import "SWRunRouteRealPath.h"
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
                       [lower containsString:@"ispass"] ||
                       [lower containsString:@"pointname"] ||
                       [lower containsString:@"pointsresmodels"] ||
                       [lower containsString:@"fivepoint"] ||
                       [lower containsString:@"markpoint"] ||
                       [lower containsString:@"fixed_point_json"] ||
                       [lower containsString:@"alllocjson"] ||
                       ([lower containsString:@"glat"] && [lower containsString:@"glon"]);
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

static id SWRunSafeValueForKey(id object, NSString *key) {
    if (!object || key.length == 0 || object == [NSNull null]) return nil;
    @try {
        id value = [object valueForKey:key];
        return value == [NSNull null] ? nil : value;
    } @catch (NSException *e) {
        return nil;
    }
}

static id SWRunValueForKeysFromObject(id object, NSArray<NSString *> *keys) {
    if (!object || object == [NSNull null]) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) {
        return SWRunValueForKeys((NSDictionary *)object, keys);
    }

    for (NSString *key in keys) {
        id value = SWRunSafeValueForKey(object, key);
        if (value) return value;
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

static NSArray<NSString *> *SWRunLatitudeKeys(void) {
    return @[@"lat", @"glat", @"gLat", @"flat", @"glocLat", @"latitude"];
}

static NSArray<NSString *> *SWRunLongitudeKeys(void) {
    return @[@"lon", @"lng", @"glon", @"gLng", @"glng", @"gLon", @"flng", @"glocLon", @"longitude"];
}

static BOOL SWRunCoordinateLooksValid(double lat, double lon) {
    return fabs(lat) >= 0.000001 && fabs(lon) >= 0.000001;
}

static BOOL SWRunCoordinateFromValue(id value, double *lat, double *lon) {
    if (!value || value == [NSNull null]) return NO;

    if ([value isKindOfClass:[CLLocation class]]) {
        CLLocationCoordinate2D coord = [(CLLocation *)value coordinate];
        if (SWRunCoordinateLooksValid(coord.latitude, coord.longitude)) {
            if (lat) *lat = coord.latitude;
            if (lon) *lon = coord.longitude;
            return YES;
        }
    }

    if ([value isKindOfClass:[NSValue class]]) {
        const char *type = [(NSValue *)value objCType];
        if (type && (strcmp(type, @encode(CLLocationCoordinate2D)) == 0 ||
                     strstr(type, "CLLocationCoordinate2D"))) {
            CLLocationCoordinate2D coord;
            [(NSValue *)value getValue:&coord];
            if (SWRunCoordinateLooksValid(coord.latitude, coord.longitude)) {
                if (lat) *lat = coord.latitude;
                if (lon) *lon = coord.longitude;
                return YES;
            }
        }
    }

    id latObj = SWRunValueForKeysFromObject(value, SWRunLatitudeKeys());
    id lonObj = SWRunValueForKeysFromObject(value, SWRunLongitudeKeys());
    if (latObj && lonObj) {
        double parsedLat = SWRunDoubleFromObject(latObj);
        double parsedLon = SWRunDoubleFromObject(lonObj);
        if (SWRunCoordinateLooksValid(parsedLat, parsedLon)) {
            if (lat) *lat = parsedLat;
            if (lon) *lon = parsedLon;
            return YES;
        }
    }

    return NO;
}

static BOOL SWRunCoordinateFromObject(id object, double *lat, double *lon) {
    if (SWRunCoordinateFromValue(object, lat, lon)) return YES;

    for (NSString *key in @[@"coordinate", @"location", @"point", @"center", @"userCoordinate"]) {
        id value = SWRunSafeValueForKey(object, key);
        if (SWRunCoordinateFromValue(value, lat, lon)) return YES;
    }

    if ([object respondsToSelector:@selector(coordinate)]) {
        @try {
            CLLocationCoordinate2D coord = ((CLLocationCoordinate2D (*)(id, SEL))objc_msgSend)(object, @selector(coordinate));
            if (SWRunCoordinateLooksValid(coord.latitude, coord.longitude)) {
                if (lat) *lat = coord.latitude;
                if (lon) *lon = coord.longitude;
                return YES;
            }
        } @catch (NSException *e) {}
    }

    return NO;
}

static BOOL SWRunDictionaryLooksLikeCheckpoint(id dict) {
    if (!dict || dict == [NSNull null]) return NO;

    double lat = 0;
    double lon = 0;
    if (!SWRunCoordinateFromObject(dict, &lat, &lon)) return NO;

    BOOL hasPointMetadata =
        SWRunValueForKeysFromObject(dict, @[@"isFixed", @"fixed", @"flag", @"pointType"]) != nil ||
        SWRunValueForKeysFromObject(dict, @[@"isPass", @"passed"]) != nil ||
        SWRunValueForKeysFromObject(dict, @[@"pointName", @"name", @"title", @"markerName"]) != nil;
    if (hasPointMetadata) return YES;

    NSString *className = NSStringFromClass([dict class]);
    return [className containsString:@"SWRunMarkPoint"] ||
           [className containsString:@"SWFivePointEntity"];
}

static NSDictionary *SWRunCheckpointDictionaryFromObject(id object) {
    if (!SWRunDictionaryLooksLikeCheckpoint(object)) return nil;
    if ([object isKindOfClass:[NSDictionary class]]) return object;

    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    double lat = 0;
    double lon = 0;
    SWRunCoordinateFromObject(object, &lat, &lon);
    id nameObj = SWRunValueForKeysFromObject(object, @[@"pointName", @"name", @"title", @"markerName"]);
    id fixedObj = SWRunValueForKeysFromObject(object, @[@"isFixed", @"fixed", @"flag", @"pointType"]);
    id passObj = SWRunValueForKeysFromObject(object, @[@"isPass", @"passed"]);
    id positionObj = SWRunValueForKeysFromObject(object, @[@"position", @"index", @"seq"]);

    if (SWRunCoordinateLooksValid(lat, lon)) dict[@"lat"] = @(lat);
    if (SWRunCoordinateLooksValid(lat, lon)) dict[@"lon"] = @(lon);
    if (nameObj) dict[@"pointName"] = nameObj;
    if (fixedObj) dict[@"isFixed"] = fixedObj;
    if (passObj) dict[@"isPass"] = passObj;
    if (positionObj) dict[@"position"] = positionObj;

    return dict.count > 0 ? dict : nil;
}

static NSArray<NSDictionary *> *SWRunPointArrayFromArray(NSArray *array) {
    if (![array isKindOfClass:[NSArray class]] || array.count == 0) return nil;

    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (id item in array) {
        NSDictionary *pointDict = SWRunCheckpointDictionaryFromObject(item);
        if (pointDict) {
            [points addObject:pointDict];
        }
    }
    return points.count > 0 ? points : nil;
}

static NSUInteger SWRunCollectionCount(id object) {
    if (!object || ![object respondsToSelector:@selector(count)]) return 0;
    @try {
        return ((NSUInteger (*)(id, SEL))objc_msgSend)(object, @selector(count));
    } @catch (NSException *e) {
        return 0;
    }
}

static id SWRunCollectionObjectAtIndex(id object, NSUInteger index) {
    if (!object || ![object respondsToSelector:@selector(objectAtIndex:)]) return nil;
    @try {
        return ((id (*)(id, SEL, NSUInteger))objc_msgSend)(object, @selector(objectAtIndex:), index);
    } @catch (NSException *e) {
        return nil;
    }
}

static NSArray<NSDictionary *> *SWRunPointArrayFromIndexedCollection(id object) {
    NSUInteger count = SWRunCollectionCount(object);
    if (count == 0) return nil;

    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    NSUInteger cappedCount = MIN(count, 300);
    for (NSUInteger i = 0; i < cappedCount; i++) {
        NSDictionary *pointDict = SWRunCheckpointDictionaryFromObject(SWRunCollectionObjectAtIndex(object, i));
        if (pointDict) {
            [points addObject:pointDict];
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

        NSArray<NSString *> *pointJsonKeys = @[
            @"fivePointJson", @"fivePoints", @"fixed_point_json",
            @"allLocJson", @"markPoints", @"markPointList"
        ];
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

    cp.pointName = SWRunValueForKeys(pointDict, @[@"pointName", @"name", @"title", @"markerName"]) ?: @"未知点位";
    cp.isFixed   = SWRunBoolFromObject(SWRunValueForKeys(pointDict, @[@"isFixed", @"fixed", @"flag", @"pointType"]));
    cp.isPassed  = SWRunBoolFromObject(SWRunValueForKeys(pointDict, @[@"isPass", @"passed"]));
    cp.position  = [pointDict[@"position"] integerValue];

    // 坐标处理
    double lat = 0;
    double lon = 0;
    SWRunCoordinateFromObject(pointDict, &lat, &lon);
    cp.longitude = lon;
    cp.latitude  = lat;

    return cp;
}

static BOOL SWRunDataLooksPointRelated(NSData *data) {
    if (!data || data.length < 10) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (body.length == 0) return NO;

    NSString *lower = [body lowercaseString];
    return [lower containsString:@"pointsresmodels"] ||
           [lower containsString:@"fivepointjson"] ||
           [lower containsString:@"fivepoints"] ||
           [lower containsString:@"fixed_point_json"] ||
           [lower containsString:@"markpoints"] ||
           [lower containsString:@"markpoint"] ||
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
static NSMutableArray<NSData *> *gPointCandidateResponses = nil;
static NSMutableArray *gRuntimeObjectCandidates = nil;

static void SWRunRememberRuntimeObject(id object) {
    if (!object || object == [NSNull null]) return;
    if (!gRuntimeObjectCandidates) {
        gRuntimeObjectCandidates = [NSMutableArray array];
    }
    @try {
        if (![gRuntimeObjectCandidates containsObject:object]) {
            [gRuntimeObjectCandidates addObject:object];
        }
        while (gRuntimeObjectCandidates.count > 32) {
            [gRuntimeObjectCandidates removeObjectAtIndex:0];
        }
    } @catch (NSException *e) {}
}

static BOOL SWRunShouldProcessResponse(NSData *data, NSString *requestURL, NSURLResponse *response) {
    NSString *responseURL = response.URL.absoluteString;
    return IsRunningRelatedURL(requestURL) ||
           IsRunningRelatedURL(responseURL) ||
           SWRunDataLooksPointRelated(data);
}

static void SWRunRememberPointCandidateData(NSData *data) {
    if (!SWRunDataLooksPointRelated(data)) return;
    if (!gPointCandidateResponses) {
        gPointCandidateResponses = [NSMutableArray array];
    }

    [gPointCandidateResponses addObject:[data copy]];
    while (gPointCandidateResponses.count > 8) {
        [gPointCandidateResponses removeObjectAtIndex:0];
    }
}

static BOOL SWRunProcessPointJSONObject(id jsonObj, NSString *source) {
    if (!jsonObj) return NO;

    @try {
        NSArray<NSDictionary *> *pointsArray = ExtractPointsFromJSON(jsonObj);
        if (!pointsArray || pointsArray.count == 0) return NO;

        NSLog(@"[SWRunHUD] 🎯 %@检测到 %lu 个打卡点",
              source.length > 0 ? [NSString stringWithFormat:@"%@: ", source] : @"",
              (unsigned long)pointsArray.count);

        NSMutableArray<SWRunCheckpoint *> *checkpoints = [NSMutableArray array];
        for (NSDictionary *pt in pointsArray) {
            if ([pt isKindOfClass:[NSDictionary class]]) {
                SWRunCheckpoint *cp = ParseCheckpoint(pt);
                if (cp.position <= 0) cp.position = checkpoints.count + 1;
                [checkpoints addObject:cp];
                NSLog(@"[SWRunHUD]   %@", cp);
            }
        }
        if (checkpoints.count == 0) return NO;

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
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[SWRunHUD] ⚠️ 点位解析异常: %@", exception.reason);
        return NO;
    }
}

static BOOL SWRunProcessPointData(NSData *data, NSString *source) {
    if (!data || data.length < 10) return NO;

    NSError *err = nil;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:&err];
    if (err || !jsonObj) return NO;
    return SWRunProcessPointJSONObject(jsonObj, source);
}

static BOOL SWRunManualParseCachedResponses(void) {
    NSArray<NSData *> *responses = [gPointCandidateResponses copy];
    for (NSData *data in [responses reverseObjectEnumerator]) {
        if (SWRunProcessPointData(data, @"缓存响应")) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *SWRunObjectGraphCandidateKeys(void) {
    return @[
        @"pointsResModels", @"fivePointJson", @"fivePoints", @"fixed_point_json",
        @"allLocJson", @"markPoints", @"markPointList", @"markpoint",
        @"cachedScoringPoints", @"cachedRunAreas", @"scoringPolygons",
        @"scoreRunPrepareImpl", @"freeRunPrepareImpl", @"outdoorRunPrepareImpl",
        @"prepareImpl", @"pointDetector", @"downloader", @"geofenceConfig",
        @"currentArea", @"currentModel", @"targetModel", @"runPolicy",
        @"runRule", @"runRuleModel", @"runArea", @"runAreaModels",
        @"runModeModel", @"freedomRunCalculate", @"freedomRunCalculateAny",
        @"runCtl", @"rawData", @"destinationPoint", @"points",
        @"pointProcessor", @"processor", @"resourceLoader",
        @"scoringProcessor", @"togetherProcessor",
        @"scoringController", @"freeingController", @"togetherController",
        @"semesterInfoModel", @"runMode", @"runCore", @"core",
        @"mapController", @"viewModel", @"dataSource", @"listDataSource",
        @"model", @"data", @"listArray", @"dataArray", @"array",
        @"scoreRunVC", @"freeRunVC", @"currentChildVC", @"selectedViewController",
        @"rootViewController", @"presentedViewController", @"children"
    ];
}

static BOOL SWRunIvarNameLooksRelevant(const char *ivarName) {
    if (!ivarName) return NO;
    return strstr(ivarName, "point") || strstr(ivarName, "Point") ||
           strstr(ivarName, "run") || strstr(ivarName, "Run") ||
           strstr(ivarName, "area") || strstr(ivarName, "Area") ||
           strstr(ivarName, "model") || strstr(ivarName, "Model") ||
           strstr(ivarName, "prepare") || strstr(ivarName, "Prepare") ||
           strstr(ivarName, "controller") || strstr(ivarName, "Controller");
}

static NSArray<NSDictionary *> *SWRunExtractPointsFromObjectGraph(id object, NSInteger depth, NSMutableSet<NSString *> *visited) {
    if (!object || object == [NSNull null] || depth < 0) return nil;

    NSDictionary *pointDict = SWRunCheckpointDictionaryFromObject(object);
    if (pointDict) return @[pointDict];

    NSArray<NSDictionary *> *directPoints = ExtractPointsFromJSON(object);
    if (directPoints) return directPoints;

    if ([object isKindOfClass:[NSData class]]) {
        NSError *err = nil;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:(NSData *)object options:0 error:&err];
        return err ? nil : ExtractPointsFromJSON(jsonObj);
    }

    if ([object isKindOfClass:[NSString class]]) {
        return ExtractPointsFromJSON(SWRunJSONFromString((NSString *)object));
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)object allValues]) {
            NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
            if (points) return points;
        }
        return nil;
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) {
            NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
            if (points) return points;
        }
        return nil;
    }

    if ([object isKindOfClass:[NSSet class]]) {
        for (id value in [(NSSet *)object allObjects]) {
            NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
            if (points) return points;
        }
        return nil;
    }

    if ([object respondsToSelector:@selector(count)] &&
        [object respondsToSelector:@selector(objectAtIndex:)]) {
        NSArray<NSDictionary *> *indexedPoints = SWRunPointArrayFromIndexedCollection(object);
        if (indexedPoints) return indexedPoints;

        NSUInteger count = MIN(SWRunCollectionCount(object), 200);
        for (NSUInteger i = 0; i < count; i++) {
            id value = SWRunCollectionObjectAtIndex(object, i);
            NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
            if (points) return points;
        }
        return nil;
    }

    if (![object isKindOfClass:[NSObject class]]) return nil;

    NSString *pointerKey = [NSString stringWithFormat:@"%p", object];
    if ([visited containsObject:pointerKey]) return nil;
    [visited addObject:pointerKey];

    NSString *className = NSStringFromClass([object class]);
    BOOL relevantObject = [className containsString:@"SW"] ||
                          [className containsString:@"Sport"] ||
                          [className containsString:@"Run"] ||
                          [object isKindOfClass:[UIViewController class]] ||
                          [object isKindOfClass:[UINavigationController class]] ||
                          [object isKindOfClass:[UITabBarController class]] ||
                          [object isKindOfClass:[UIWindow class]];
    if (!relevantObject) return nil;

    for (NSString *key in SWRunObjectGraphCandidateKeys()) {
        id value = SWRunSafeValueForKey(object, key);
        NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
        if (points) return points;
    }

    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([object class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        Ivar ivar = ivars[i];
        const char *type = ivar_getTypeEncoding(ivar);
        const char *name = ivar_getName(ivar);
        if (!type || type[0] != '@' || !SWRunIvarNameLooksRelevant(name)) continue;

        id value = nil;
        @try {
            value = object_getIvar(object, ivar);
        } @catch (NSException *e) {
            value = nil;
        }

        NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(value, depth - 1, visited);
        if (points) {
            free(ivars);
            return points;
        }
    }
    if (ivars) free(ivars);

    return nil;
}

static void SWRunCollectViewControllerRoots(UIViewController *vc, NSMutableArray *roots) {
    if (!vc || [roots containsObject:vc]) return;
    [roots addObject:vc];

    if (vc.presentedViewController) {
        SWRunCollectViewControllerRoots(vc.presentedViewController, roots);
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        for (UIViewController *child in nav.viewControllers) {
            SWRunCollectViewControllerRoots(child, roots);
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)vc;
        for (UIViewController *child in tab.viewControllers) {
            SWRunCollectViewControllerRoots(child, roots);
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        SWRunCollectViewControllerRoots(child, roots);
    }
}

static BOOL SWRunManualParseRuntimeObjects(void) {
    NSMutableArray *roots = [NSMutableArray array];
    UIApplication *app = UIApplication.sharedApplication;
    if (app.delegate) [roots addObject:app.delegate];

    for (id object in [gRuntimeObjectCandidates copy]) {
        if (object && ![roots containsObject:object]) {
            [roots addObject:object];
        }
    }

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                [windows addObjectsFromArray:windowScene.windows];
            }
        }
    } else {
        NSArray *legacyWindows = SWRunSafeValueForKey(app, @"windows");
        if ([legacyWindows isKindOfClass:[NSArray class]]) {
            [windows addObjectsFromArray:legacyWindows];
        }
    }

    for (UIWindow *window in windows) {
        if (![roots containsObject:window]) [roots addObject:window];
        SWRunCollectViewControllerRoots(window.rootViewController, roots);
    }

    for (id root in roots) {
        NSMutableSet<NSString *> *visited = [NSMutableSet set];
        NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(root, 5, visited);
        if (points && SWRunProcessPointJSONObject(points, [NSString stringWithFormat:@"手动扫描 %@", NSStringFromClass([root class])])) {
            return YES;
        }
    }
    return NO;
}

static void SWRunTryProcessRuntimeObject(id object, NSString *source) {
    if (!object) return;
    SWRunRememberRuntimeObject(object);

    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSArray<NSDictionary *> *points = SWRunExtractPointsFromObjectGraph(object, 8, visited);
    if (points) {
        SWRunProcessPointJSONObject(points, source);
    }
}

static NSMutableDictionary<NSString *, NSValue *> *gPointAccessorOriginalIMPs = nil;
static BOOL gPointAccessorPatchInstalled = NO;
static __thread BOOL gPointAccessorProcessing = NO;

static NSString *SWRunAccessorIMPKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s:%@", class_getName(cls), NSStringFromSelector(sel)];
}

static IMP SWRunOriginalAccessorIMP(id self, SEL sel) {
    if (!self || !gPointAccessorOriginalIMPs) return NULL;
    Class cls = [self class];
    while (cls) {
        NSString *key = SWRunAccessorIMPKey(cls, sel);
        NSValue *value = gPointAccessorOriginalIMPs[key];
        if (value) return [value pointerValue];
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void SWRunPointObjectSetter(id self, SEL _cmd, id value) {
    if (!gPointAccessorProcessing) {
        gPointAccessorProcessing = YES;
        SWRunTryProcessRuntimeObject(value, [NSString stringWithFormat:@"属性捕获 %@", NSStringFromSelector(_cmd)]);
        gPointAccessorProcessing = NO;
    }

    IMP originalIMP = SWRunOriginalAccessorIMP(self, _cmd);
    if (originalIMP) {
        ((void (*)(id, SEL, id))originalIMP)(self, _cmd, value);
    }
}

static id SWRunPointObjectGetter(id self, SEL _cmd) {
    id value = nil;
    IMP originalIMP = SWRunOriginalAccessorIMP(self, _cmd);
    if (originalIMP) {
        value = ((id (*)(id, SEL))originalIMP)(self, _cmd);
    }
    if (!gPointAccessorProcessing) {
        gPointAccessorProcessing = YES;
        SWRunTryProcessRuntimeObject(value, [NSString stringWithFormat:@"属性读取 %@", NSStringFromSelector(_cmd)]);
        gPointAccessorProcessing = NO;
    }
    return value;
}

static BOOL SWRunMethodReturnsObject(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char type[16] = {0};
    method_getReturnType(method, type, sizeof(type));
    return type[0] == '@';
}

static BOOL SWRunMethodTakesObject(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return NO;
    char type[16] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    return type[0] == '@';
}

static BOOL SWRunClassShouldPatchPointAccessors(Class cls) {
    const char *imageName = class_getImageName(cls);
    const char *className = class_getName(cls);
    if (!imageName || !className) return NO;
    if (strstr(imageName, "SWCampus.app/") == NULL) return NO;

    return strstr(className, "SWRun") != NULL ||
           strstr(className, "Sport") != NULL ||
           strstr(className, "Point") != NULL ||
           strstr(className, "Run") != NULL;
}

static BOOL SWRunClassDefinesInstanceMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return NO;

    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void SWRunPatchPointAccessorMethod(Class cls, SEL sel, IMP replacement, BOOL isGetter) {
    if (!SWRunClassDefinesInstanceMethod(cls, sel)) return;

    Method method = class_getInstanceMethod(cls, sel);
    if (isGetter) {
        if (!SWRunMethodReturnsObject(method)) return;
    } else {
        if (!SWRunMethodTakesObject(method)) return;
    }

    NSString *key = SWRunAccessorIMPKey(cls, sel);
    if (gPointAccessorOriginalIMPs[key]) return;

    IMP originalIMP = method_getImplementation(method);
    gPointAccessorOriginalIMPs[key] = [NSValue valueWithPointer:originalIMP];
    method_setImplementation(method, replacement);
}

static void SWRunPatchPointAccessors(void) {
    if (gPointAccessorPatchInstalled) return;
    gPointAccessorPatchInstalled = YES;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;

    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    int actualCount = objc_getClassList(classes, count);
    if (actualCount > count) actualCount = count;

    gPointAccessorOriginalIMPs = [NSMutableDictionary dictionary];

    NSArray<NSString *> *getterNames = @[
        @"markPoints", @"fivePoints", @"points", @"pointsResModels",
        @"rawData", @"destinationPoint", @"pointProcessor", @"processor",
        @"resourceLoader", @"scoringProcessor", @"togetherProcessor",
        @"loader", @"downloader", @"runCtl", @"runCore", @"core"
    ];
    NSArray<NSString *> *setterNames = @[
        @"setMarkPoints:", @"setFivePoints:", @"setPoints:",
        @"setPointsResModels:", @"setRawData:", @"setDestinationPoint:",
        @"setPointProcessor:", @"setProcessor:", @"setResourceLoader:",
        @"setScoringProcessor:", @"setTogetherProcessor:", @"setLoader:",
        @"setDownloader:", @"setRunCtl:", @"setRunCore:", @"setCore:"
    ];

    for (int i = 0; i < actualCount; i++) {
        Class cls = classes[i];
        if (!SWRunClassShouldPatchPointAccessors(cls)) continue;

        for (NSString *name in getterNames) {
            SWRunPatchPointAccessorMethod(cls, NSSelectorFromString(name), (IMP)SWRunPointObjectGetter, YES);
        }
        for (NSString *name in setterNames) {
            SWRunPatchPointAccessorMethod(cls, NSSelectorFromString(name), (IMP)SWRunPointObjectSetter, NO);
        }
    }

    free(classes);
}

void SWRunForceParseCheckpoints(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[SWRunHUD] 🔎 手动解析点位开始");
        NSLog(@"[SWRunHUD] 🔎 当前候选: 缓存响应=%lu 运行时对象=%lu",
              (unsigned long)gPointCandidateResponses.count,
              (unsigned long)gRuntimeObjectCandidates.count);
        BOOL parsed = SWRunManualParseCachedResponses();
        if (!parsed) {
            parsed = SWRunManualParseRuntimeObjects();
        }

        if (!parsed) {
            NSLog(@"[SWRunHUD] ❌ 手动解析点位失败: 缓存响应和当前页面对象图均未发现点位");
        }
    });
}

%hook NSURLSession

// ★ %new 必须在引用它的 hook 方法之前定义
%new
- (void)swrun_processResponseData:(NSData *)data {
    SWRunProcessPointData(data, @"网络响应");
}

// ★ 拦截 dataTaskWithRequest:completionHandler:
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *urlStr = request.URL.absoluteString;
    if (IsRunningRelatedURL(urlStr)) {
        gLastRunningURL = [urlStr copy];
    }

    void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error) {
            SWRunRememberPointCandidateData(data);
        }
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
        if (data && !error) {
            SWRunRememberPointCandidateData(data);
        }
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
#pragma mark - Hook: 跑步核心对象缓存
// ============================================================

%hook SWRunCoreRandom

- (void)start {
    SWRunRememberRuntimeObject(self);
    %orig;
    SWRunTryProcessRuntimeObject(self, @"随机点跑核心");
}

- (void)restart {
    SWRunRememberRuntimeObject(self);
    %orig;
    SWRunTryProcessRuntimeObject(self, @"随机点跑核心");
}

%end

%hook SWRunCoreSequence

- (void)start {
    SWRunRememberRuntimeObject(self);
    %orig;
    SWRunTryProcessRuntimeObject(self, @"顺序点跑核心");
}

- (void)restart {
    SWRunRememberRuntimeObject(self);
    %orig;
    SWRunTryProcessRuntimeObject(self, @"顺序点跑核心");
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
static BOOL        gSimStarting      = NO;
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

static NSTimeInterval SWRunLocationAge(CLLocation *loc) {
    NSDate *timestamp = loc.timestamp;
    if (!timestamp) return 999999.0;
    NSTimeInterval age = fabs([timestamp timeIntervalSinceNow]);
    return isfinite(age) ? age : 999999.0;
}

static BOOL SWRunLocationIsFresh(CLLocation *loc) {
    if (!loc || !SWRunCoordinateLooksUsable(loc.coordinate)) return NO;
    CLLocationAccuracy accuracy = loc.horizontalAccuracy;
    if (accuracy < 0 || accuracy > 120.0) return NO;
    return SWRunLocationAge(loc) <= 20.0;
}

static CLLocation *SWRunBetterRealLocation(CLLocation *candidate, CLLocation *currentBest) {
    if (!candidate || !SWRunCoordinateLooksUsable(candidate.coordinate)) return currentBest;
    if (!currentBest || !SWRunCoordinateLooksUsable(currentBest.coordinate)) return candidate;

    BOOL candidateFresh = SWRunLocationIsFresh(candidate);
    BOOL bestFresh = SWRunLocationIsFresh(currentBest);
    if (candidateFresh != bestFresh) return candidateFresh ? candidate : currentBest;

    NSTimeInterval candidateAge = SWRunLocationAge(candidate);
    NSTimeInterval bestAge = SWRunLocationAge(currentBest);
    CLLocationAccuracy candidateAccuracy = candidate.horizontalAccuracy;
    CLLocationAccuracy bestAccuracy = currentBest.horizontalAccuracy;
    BOOL candidateHasAccuracy = candidateAccuracy >= 0;
    BOOL bestHasAccuracy = bestAccuracy >= 0;

    if (candidateHasAccuracy != bestHasAccuracy) return candidateHasAccuracy ? candidate : currentBest;
    if (candidateHasAccuracy && fabs(candidateAccuracy - bestAccuracy) > 10.0) {
        return candidateAccuracy < bestAccuracy ? candidate : currentBest;
    }
    if (fabs(candidateAge - bestAge) > 5.0) return candidateAge < bestAge ? candidate : currentBest;
    if (candidateHasAccuracy && candidateAccuracy < bestAccuracy) return candidate;
    return currentBest;
}

static CLLocation *SWRunLocationFromProvider(id provider) {
    if (!provider) return nil;

    CLLocation *best = nil;
    NSArray<NSString *> *selectors = @[@"location", @"currentLocation"];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![provider respondsToSelector:selector]) continue;

        @try {
            id value = ((id(*)(id, SEL))objc_msgSend)(provider, selector);
            if ([value isKindOfClass:[CLLocation class]]) {
                best = SWRunBetterRealLocation((CLLocation *)value, best);
            }
        } @catch (NSException *e) {}
    }
    return best;
}

static CLLocation *SWRunCurrentRealStartLocation(void) {
    SWRunEnsureLocationContainers();

    CLLocation *amapBest = nil;
    for (id mgr in gAMapLocationManagers) {
        amapBest = SWRunBetterRealLocation(SWRunLocationFromProvider(mgr), amapBest);
    }

    CLLocation *coreBest = nil;
    for (CLLocationManager *mgr in gLocationManagers) {
        coreBest = SWRunBetterRealLocation([mgr location], coreBest);
    }

    CLLocation *best = SWRunLocationIsFresh(amapBest) ? amapBest : SWRunBetterRealLocation(amapBest, coreBest);
    if ((!best || !SWRunLocationIsFresh(best)) && gPreflightLocation) {
        best = SWRunBetterRealLocation(gPreflightLocation, best);
    }

    if (best && SWRunLocationAge(best) > 45.0) {
        NSLog(@"[SWRunHUD] 真实起点候选已过期: age=%.1fs acc=%.1fm",
              SWRunLocationAge(best),
              best.horizontalAccuracy);
        return nil;
    }

    CLLocation *strongLoc = SWRunBuildStrongGPSLocation(best);
    if (strongLoc) {
        gPreflightLocation = strongLoc;
        NSLog(@"[SWRunHUD] 真实起点候选: %.6f, %.6f age=%.1fs acc=%.1fm",
              best.coordinate.latitude,
              best.coordinate.longitude,
              SWRunLocationAge(best),
              best.horizontalAccuracy);
        return strongLoc;
    }
    return nil;
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

static NSArray<NSValue *> *SWRunBuildRouteControls(SWRunFloatingView *hud,
                                                   SWRunRoutePlan *plan,
                                                   CLLocation *realStartLocation) {
    if (!hud || !plan || plan.optimalOrder.count < 2) return @[];

    NSArray<SWRunCheckpoint *> *checkpoints = [hud valueForKey:@"checkpoints"];
    if (![checkpoints isKindOfClass:[NSArray class]] || checkpoints.count < 2) return @[];

    NSMutableArray<NSValue *> *coords = [NSMutableArray array];
    if (realStartLocation && SWRunCoordinateLooksUsable(realStartLocation.coordinate)) {
        [coords addObject:[NSValue valueWithMKCoordinate:realStartLocation.coordinate]];
    }

    for (NSNumber *idxNum in plan.optimalOrder) {
        NSInteger idx = [idxNum integerValue];
        if (idx < 0 || idx >= checkpoints.count) continue;
        SWRunCheckpoint *cp = checkpoints[idx];
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(cp.latitude, cp.longitude);
        if (!SWRunCoordinateLooksUsable(coord)) continue;
        [coords addObject:[NSValue valueWithMKCoordinate:coord]];
    }

    return coords;
}

static NSString *SWRunCurrentTargetLabel(SWRunSimulator *sim) {
    if (sim.currentTargetIndex >= 0) {
        return [NSString stringWithFormat:@"P%ld", (long)(sim.currentTargetIndex + 1)];
    }
    return @"补足距离";
}

static NSString *SWRunPaceText(double secondsPerMeter) {
    if (secondsPerMeter <= 0 || !isfinite(secondsPerMeter)) return @"--'--\"";
    NSInteger totalSeconds = (NSInteger)llround(secondsPerMeter * 1000.0);
    return [NSString stringWithFormat:@"%ld'%02ld\"",
            (long)(totalSeconds / 60),
            (long)(totalSeconds % 60)];
}

/// 启动GPS模拟 — 由浮动窗按钮触发
void SWRunStartGPSSimulation(void) {
    if (gSimActive || gSimStarting) return;

    // 获取当前路线规划
    SWRunFloatingView *hud = [SWRunFloatingView sharedInstance];
    SWRunRoutePlan *plan = [hud valueForKey:@"currentPlan"];

    if (!plan || plan.optimalOrder.count < 2) {
        NSLog(@"[SWRunHUD] ❌ 没有路线规划, 无法模拟");
        return;
    }

    CLLocation *realStartLocation = SWRunCurrentRealStartLocation();
    if (realStartLocation) {
        [hud updateCurrentLocation:realStartLocation.coordinate.latitude
                                lng:realStartLocation.coordinate.longitude];
        NSLog(@"[SWRunHUD] 📍 使用真实当前位置作为起点: %.6f, %.6f",
              realStartLocation.coordinate.latitude,
              realStartLocation.coordinate.longitude);
    } else {
        NSLog(@"[SWRunHUD] ⚠️ 未取得真实当前位置, 已取消模拟启动");
        [hud updateSimulationStatus:@"未取得真实当前位置，请等定位稳定后重试" location:nil];
        return;
    }

    NSArray<NSValue *> *routeControls = SWRunBuildRouteControls(hud, plan, realStartLocation);
    gSimStarting = YES;
    gSimLocation = SWRunBuildStrongGPSLocation(realStartLocation) ?: realStartLocation;
    gSimActive = YES;
    [hud updateSimulationStatus:@"正在获取真实步行路线..." location:realStartLocation];
    [hud setSimulationRunning:YES];
    SWRunDeliverLocationToDelegates(gSimLocation);
    SWRunDeliverHeadingToDelegates();

    [[SWRunRouteRealPath sharedInstance] walkingRouteCoordinatesForCoordinates:routeControls
                                                                    completion:^(NSArray<NSValue *> *routeCoordinates, SWPathSource routeSource) {
        if (!gSimStarting) return;
        gSimStarting = NO;
        NSLog(@"[SWRunHUD] 🛤 真实路线坐标已准备: %lu 个点, 来源=%ld",
              (unsigned long)routeCoordinates.count, (long)routeSource);

        NSArray<NSValue *> *simRouteCoordinates = routeCoordinates.count >= 2 ? routeCoordinates : routeControls;

        [[SWRunSimulator sharedInstance]
        startSimulationWithCheckpoints:[hud valueForKey:@"checkpoints"]
                          visitOrder:plan.optimalOrder
                        startLocation:gSimLocation ?: realStartLocation
                     routeCoordinates:simRouteCoordinates
                     onTick:^(CLLocation *loc, NSInteger step) {
        gSimLocation = SWRunBuildStrongGPSLocation(loc) ?: loc;
        gSimActive = YES;

        // ★ 更新悬浮窗状态标签
        SWRunSimulator *sim = [SWRunSimulator sharedInstance];
        SWSimulatedMotionData *md = sim.motionData;
        NSString *targetLabel = SWRunCurrentTargetLabel(sim);
        NSString *paceText = SWRunPaceText(md.currentPace);
        NSString *status = [NSString stringWithFormat:
            @"模拟中 %.0f/%.0fm  %.0fs\n步数 %ld  步频 %.0f步/分  配速 %@/km\n海拔 %.1fm  气压 %.2fkPa  航向 %.0f°\n当前位置 %.6f, %.6f  目标 %@",
            sim.traveledDistance, sim.totalPathDistance,
            sim.elapsedSeconds,
            (long)md.numberOfSteps,
            md.currentCadence * 60.0,
            paceText,
            md.currentAltitude,
            md.currentPressure,
            md.currentHeading,
            gSimLocation.coordinate.latitude,
            gSimLocation.coordinate.longitude,
            targetLabel];
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud updateSimulationStatus:status location:gSimLocation];
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
        gSimStarting = NO;
        gSimActive = NO;
        gSimLocation = nil;
        SWRunStopGPSSimulation();
        NSLog(@"[SWRunHUD] %@", finished ? @"✅ GPS模拟完成" : @"❌ GPS模拟异常终止");
    }];

        // 更新悬浮窗状态
        if ([SWRunSimulator sharedInstance].state == SWSimulatorStateRunning) {
            [hud setSimulationRunning:YES];
        }
    }];
}

/// 停止GPS模拟
void SWRunStopGPSSimulation(void) {
    [[SWRunSimulator sharedInstance] stop];
    gSimStarting = NO;
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
    if (loc) return loc;
    return SWRunLocationIsFresh(gPreflightLocation) ? gPreflightLocation : nil;
}

- (void)startUpdatingLocation {
    if (gSimActive) {
        // 模拟模式: 仍然调用原始方法以维持内部状态
        // 但实际位置由 SWRunSimulator 通过 delegate 回调注入
        NSLog(@"[SWRunHUD] 📍 startUpdatingLocation → GPS模拟已接管");
        SWRunDeliverLocationToDelegates(gSimLocation);
    }
    %orig;

    if (!gSimActive && SWRunLocationIsFresh(gPreflightLocation)) {
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
    if (SWRunLocationIsFresh(gPreflightLocation)) {
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
    return %orig;
}

- (CLLocationDistance)altitude {
    return %orig;
}

- (CLLocationAccuracy)horizontalAccuracy {
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 4.0);
}

- (CLLocationAccuracy)verticalAccuracy {
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 3.0);
}

- (CLLocationDirection)course {
    return %orig;
}

- (CLLocationSpeed)speed {
    return %orig;
}

- (NSDate *)timestamp {
    return %orig;
}

- (CLLocationAccuracy)speedAccuracy {
    CLLocationAccuracy accuracy = %orig;
    if (accuracy < 0) return accuracy;
    return MIN(accuracy, 0.3);
}

- (CLLocationDirectionAccuracy)courseAccuracy {
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

/// 缓存系统真实回调对象，避免构造空壳 CMPedometerData。
static CMPedometerData *gLastPedometerData = nil;

static BOOL SWRunShouldSpoofMotionData(void) {
    if (!gSimActive) return NO;
    SWSimulatorState state = [SWRunSimulator sharedInstance].state;
    return state == SWSimulatorStateRunning || state == SWSimulatorStatePaused;
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
        CMPedometerHandler wrappedHandler = ^(CMPedometerData *data, NSError *error) {
            if (data) {
                gLastPedometerData = data;
            }
            if (SWRunShouldSpoofMotionData()) {
                CMPedometerData *targetData = data ?: gLastPedometerData;
                if (targetData) {
                    handler(targetData, nil);
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

    if (SWRunShouldSpoofMotionData()) {
        CMPedometerHandler wrappedHandler = ^(CMPedometerData *data, NSError *error) {
            if (data) {
                gLastPedometerData = data;
            }
            CMPedometerData *targetData = data ?: gLastPedometerData;
            if (targetData) {
                handler(targetData, nil);
            } else {
                handler(data, error);
            }
        };
        %orig(start, end, wrappedHandler);
        return;
    }
    %orig;
}

%end

%hook CMPedometerData

- (NSNumber *)numberOfSteps {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.numberOfSteps);
    return %orig;
}

- (NSNumber *)distance {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.distance);
    return %orig;
}

- (NSDate *)startDate {
    if (SWRunShouldSpoofMotionData()) {
        NSDate *start = [SWRunSimulator sharedInstance].simulationStartDate;
        if (start) return start;
    }
    return %orig;
}

- (NSDate *)endDate {
    if (SWRunShouldSpoofMotionData()) return [NSDate date];
    return %orig;
}

- (NSNumber *)averageActivePace {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.averageActivePace);
    return %orig;
}

- (NSNumber *)currentPace {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.currentPace);
    return %orig;
}

- (NSNumber *)currentCadence {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.currentCadence);
    return %orig;
}

- (NSNumber *)floorsAscended {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.floorsAscended);
    return %orig;
}

- (NSNumber *)floorsDescended {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.floorsDescended);
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

static CMMotionActivity *gLastMotionActivity = nil;

%hook CMMotionManager

- (BOOL)isAccelerometerAvailable {
    return %orig;
}

- (BOOL)isGyroAvailable {
    return %orig;
}

- (BOOL)isDeviceMotionAvailable {
    return %orig;
}

- (BOOL)isAccelerometerActive {
    return %orig;
}

- (BOOL)isGyroActive {
    return %orig;
}

- (BOOL)isDeviceMotionActive {
    return %orig;
}

- (CMAccelerometerData *)accelerometerData {
    return %orig;
}

- (CMGyroData *)gyroData {
    return %orig;
}

- (CMDeviceMotion *)deviceMotion {
    return %orig;
}

- (void)startAccelerometerUpdates {
    if (SWRunShouldSpoofMotionData()) NSLog(@"[SWRunHUD] CMMotionManager accelerometer -> 模拟数据已接管");
    %orig;
}

- (void)startGyroUpdates {
    if (SWRunShouldSpoofMotionData()) NSLog(@"[SWRunHUD] CMMotionManager gyro -> 模拟数据已接管");
    %orig;
}

- (void)startDeviceMotionUpdates {
    if (SWRunShouldSpoofMotionData()) NSLog(@"[SWRunHUD] CMMotionManager deviceMotion -> 模拟数据已接管");
    %orig;
}

- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue
                             withHandler:(CMAccelerometerHandler)handler {
    %orig;
}

- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue
                    withHandler:(CMGyroHandler)handler {
    %orig;
}

- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMDeviceMotionHandler)handler {
    %orig;
}

%end

%hook CMAccelerometerData

- (CMAcceleration)acceleration {
    if (SWRunShouldSpoofMotionData()) return SWRunFakeAccelerometer();
    return %orig;
}

%end

%hook CMGyroData

- (CMRotationRate)rotationRate {
    if (SWRunShouldSpoofMotionData()) return SWRunFakeRotationRate();
    return %orig;
}

%end

%hook CMDeviceMotion

- (CMAcceleration)userAcceleration {
    if (SWRunShouldSpoofMotionData()) return SWRunFakeUserAcceleration();
    return %orig;
}

- (CMAcceleration)gravity {
    if (SWRunShouldSpoofMotionData()) return SWRunFakeGravity();
    return %orig;
}

- (CMRotationRate)rotationRate {
    if (SWRunShouldSpoofMotionData()) return SWRunFakeRotationRate();
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
        CMMotionActivityHandler wrappedHandler = ^(CMMotionActivity *activity) {
            if (activity) {
                gLastMotionActivity = activity;
            }
            if (SWRunShouldSpoofMotionData()) {
                CMMotionActivity *targetActivity = activity ?: gLastMotionActivity;
                handler(targetActivity);
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

    if (SWRunShouldSpoofMotionData() && gLastMotionActivity) {
        NSOperationQueue *targetQueue = queue ?: [NSOperationQueue mainQueue];
        [targetQueue addOperationWithBlock:^{
            handler(@[gLastMotionActivity], nil);
        }];
        return;
    }
    %orig;
}

%end

%hook CMMotionActivity

- (BOOL)stationary {
    if (SWRunShouldSpoofMotionData()) return NO;
    return %orig;
}

- (BOOL)walking {
    if (SWRunShouldSpoofMotionData()) return NO;
    return %orig;
}

- (BOOL)running {
    if (SWRunShouldSpoofMotionData()) return YES;
    return %orig;
}

- (BOOL)automotive {
    if (SWRunShouldSpoofMotionData()) return NO;
    return %orig;
}

- (BOOL)cycling {
    if (SWRunShouldSpoofMotionData()) return NO;
    return %orig;
}

- (CMMotionActivityConfidence)confidence {
    if (SWRunShouldSpoofMotionData()) return CMMotionActivityConfidenceHigh;
    return %orig;
}

- (NSDate *)startDate {
    if (SWRunShouldSpoofMotionData()) return [SWRunSimulator sharedInstance].simulationStartDate ?: [NSDate date];
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
            if (SWRunShouldSpoofMotionData() && data) {
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
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.relativeAltitude);
    return %orig;
}

- (NSNumber *)pressure {
    if (SWRunShouldSpoofMotionData()) return @([SWRunSimulator sharedInstance].motionData.currentPressure);
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
                SWRunPatchPointAccessors();
                NSLog(@"[SWRunHUD] ✅ 悬浮窗系统初始化完成");
                NSLog(@"[SWRunHUD] 📱 运动世界 校园跑点位监控已激活");
                NSLog(@"[SWRunHUD] 🔴 必经点(isFixed=1) 将显示为红色");
                NSLog(@"[SWRunHUD] 🔵 普通点(isFixed=0) 将显示为蓝色");
                NSLog(@"[SWRunHUD] 👆 点击悬浮球展开, 拖拽移动, 不再自动收起");
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
        [className containsString:@"Sport"] ||
        [className containsString:@"Running"] ||
        [className containsString:@"Run"]) {

        NSLog(@"[SWRunHUD] 🏃 进入跑步页面: %@", className);
        SWRunRememberRuntimeObject(self);

        // 确保悬浮窗可用
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            [[SWRunFloatingView sharedInstance] showCollapsed];
            SWRunTryProcessRuntimeObject(self, [NSString stringWithFormat:@"页面对象 %@", className]);
        });
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    if ([className hasPrefix:@"SWRun"] ||
        [className hasPrefix:@"SWSport"] ||
        [className hasPrefix:@"SWIndoor"] ||
        [className containsString:@"Sport"]) {

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
            SWRunPatchPointAccessors();
            NSLog(@"[SWRunHUD] 🔄 App 进入前台, 悬浮球已显示");
        });
    }];

    NSLog(@"[SWRunHUD] ✅ 所有 Hooks 安装完毕");
}
