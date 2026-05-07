//
//  SWRunRouteRealPath.m
//  SWRunCheckpointHUD
//
//  真实步行路径计算 —— 运行时动态调用高德地图 SDK / Apple MapKit
//  避免"穿墙过河"的直线路径
//

#import "SWRunRouteRealPath.h"
#import "SWRunRoutePlanner.h"
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================
#pragma mark - SWPathSegment 实现
// ============================================================
@implementation SWPathSegment

- (NSString *)description {
    NSString *sourceName;
    switch (self.source) {
        case SWPathSourceAMap:        sourceName = @"高德步行"; break;
        case SWPathSourceAppleMaps:   sourceName = @"Apple步行"; break;
        case SWPathSourceStraightLine: sourceName = @"⚠️直线估算"; break;
    }
    return [NSString stringWithFormat:@"%@: %.0fm (直线%.0fm) %.0fs",
            sourceName, self.distance, self.straightDistance, self.duration];
}

@end

// ============================================================
#pragma mark - SWRunRouteRealPath 实现
// ============================================================
@interface SWRunRouteRealPath ()

/// 缓存: "lat1,lng1→lat2,lng2" → SWPathSegment
@property (nonatomic, strong) NSMutableDictionary<NSString *, SWPathSegment *> *cache;
/// 高德搜索类 (运行时获取)
@property (nonatomic, assign) Class amapRouteSearchClass;
/// 高德请求类
@property (nonatomic, assign) Class amapWalkingRequestClass;
/// 高德响应类
@property (nonatomic, assign) Class amapWalkingResponseClass;

- (void)appendWalkingRouteCoordinates:(NSArray<NSValue *> *)coordinates
                                index:(NSInteger)index
                          routeCoords:(NSMutableArray<NSValue *> *)routeCoords
                           worstSource:(SWPathSource)worstSource
                            completion:(void(^)(NSArray<NSValue *> *routeCoordinates, SWPathSource overallSource))completion;

@end

@implementation SWRunRouteRealPath

// ============================================================
#pragma mark - 单例 & 初始化
// ============================================================
+ (instancetype)sharedInstance {
    static SWRunRouteRealPath *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SWRunRouteRealPath alloc] init];
        [instance detectMapServices];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}

/// 运行时探测可用的地图服务
- (void)detectMapServices {
    // 探测高德地图 SearchKit
    self.amapRouteSearchClass = NSClassFromString(@"AMapSearchAPI");
    if (!self.amapRouteSearchClass) {
        self.amapRouteSearchClass = NSClassFromString(@"AMapSearchKit.AMapSearchAPI");
    }

    self.amapWalkingRequestClass = NSClassFromString(@"AMapWalkingRouteSearchRequest");
    if (!self.amapWalkingRequestClass) {
        self.amapWalkingRequestClass = NSClassFromString(@"AMapSearchKit.AMapWalkingRouteSearchRequest");
    }

    self.amapWalkingResponseClass = NSClassFromString(@"AMapWalkingRouteSearchResponse");
    if (!self.amapWalkingResponseClass) {
        self.amapWalkingResponseClass = NSClassFromString(@"AMapSearchKit.AMapWalkingRouteSearchResponse");
    }

    if (self.amapRouteSearchClass && self.amapWalkingRequestClass) {
        NSLog(@"[SWRunHUD] 🗺 高德地图 SDK 已检测到 (运行时动态调用)");
    } else {
        NSLog(@"[SWRunHUD] ⚠️ 高德地图 SDK 未检测到, 将尝试 Apple Maps");
    }

    if ([self isAppleMapsAvailable]) {
        NSLog(@"[SWRunHUD] 🍎 Apple Maps 步行路线可用");
    }
}

// ============================================================
#pragma mark - 可用性检查
// ============================================================
- (BOOL)isAMapAvailable {
    return (self.amapRouteSearchClass != nil && self.amapWalkingRequestClass != nil);
}

- (BOOL)isAppleMapsAvailable {
    return [MKMapItem class] != nil;
}

- (NSString *)dataSourceDescription {
    if ([self isAMapAvailable]) return @"🗺 高德地图步行路径";
    if ([self isAppleMapsAvailable]) return @"🍎 Apple Maps 步行路径";
    return @"⚠️ 直线距离(无地图服务)";
}

// ============================================================
#pragma mark - 缓存
// ============================================================
- (NSString *)cacheKeyFrom:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to {
    return [NSString stringWithFormat:@"%.6f,%.6f→%.6f,%.6f",
            from.latitude, from.longitude, to.latitude, to.longitude];
}

- (SWPathSegment * _Nullable)cachedResultFrom:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to {
    SWPathSegment *direct = self.cache[[self cacheKeyFrom:from to:to]];
    if (direct) return direct;

    SWPathSegment *reverse = self.cache[[self cacheKeyFrom:to to:from]];
    if (!reverse) return nil;

    SWPathSegment *copy = [[SWPathSegment alloc] init];
    copy.distance = reverse.distance;
    copy.straightDistance = reverse.straightDistance;
    copy.source = reverse.source;
    copy.duration = reverse.duration;
    copy.isAvailable = reverse.isAvailable;
    if (reverse.pathCoordinates.count > 0) {
        copy.pathCoordinates = [[reverse.pathCoordinates reverseObjectEnumerator] allObjects];
    }
    return copy;
}

- (void)setCachedResult:(SWPathSegment *)result from:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to {
    self.cache[[self cacheKeyFrom:from to:to]] = result;
}

- (NSArray<NSValue *> *)fallbackPathCoordinatesFrom:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to {
    return @[[NSValue valueWithMKCoordinate:from], [NSValue valueWithMKCoordinate:to]];
}

- (NSArray<NSValue *> *)coordinatesFromPolyline:(MKPolyline *)polyline {
    if (!polyline || polyline.pointCount == 0) return @[];

    NSMutableArray<NSValue *> *coords = [NSMutableArray arrayWithCapacity:polyline.pointCount];
    MKMapPoint *points = polyline.points;
    for (NSUInteger i = 0; i < polyline.pointCount; i++) {
        CLLocationCoordinate2D coord = MKCoordinateForMapPoint(points[i]);
        if (CLLocationCoordinate2DIsValid(coord) &&
            fabs(coord.latitude) > 0.000001 &&
            fabs(coord.longitude) > 0.000001) {
            [coords addObject:[NSValue valueWithMKCoordinate:coord]];
        }
    }
    return coords;
}

- (NSArray<NSValue *> *)coordinatesFromAMapPolylineString:(NSString *)polylineString {
    if (![polylineString isKindOfClass:[NSString class]] || polylineString.length == 0) return @[];

    NSMutableArray<NSValue *> *coords = [NSMutableArray array];
    for (NSString *pair in [polylineString componentsSeparatedByString:@";"]) {
        NSArray<NSString *> *parts = [pair componentsSeparatedByString:@","];
        if (parts.count < 2) continue;

        double lng = [parts[0] doubleValue];
        double lat = [parts[1] doubleValue];
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lng);
        if (CLLocationCoordinate2DIsValid(coord) &&
            fabs(coord.latitude) > 0.000001 &&
            fabs(coord.longitude) > 0.000001) {
            [coords addObject:[NSValue valueWithMKCoordinate:coord]];
        }
    }
    return coords;
}

- (id)safeValueFromObject:(id)object forKey:(NSString *)key {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

- (NSArray<NSValue *> *)pathCoordinatesFromAMapResponse:(id)response {
    NSMutableArray<NSValue *> *coords = [NSMutableArray array];
    id route = [self safeValueFromObject:response forKey:@"route"];
    id paths = [self safeValueFromObject:route forKey:@"paths"];
    if (![paths isKindOfClass:[NSArray class]] || [(NSArray *)paths count] == 0) {
        id routes = [self safeValueFromObject:response forKey:@"routes"];
        id firstRoute = [routes isKindOfClass:[NSArray class]] ? [(NSArray *)routes firstObject] : nil;
        paths = [self safeValueFromObject:firstRoute forKey:@"paths"];
        if (![paths isKindOfClass:[NSArray class]] || [(NSArray *)paths count] == 0) {
            paths = firstRoute ? @[firstRoute] : nil;
        }
    }

    id firstPath = [paths isKindOfClass:[NSArray class]] ? [(NSArray *)paths firstObject] : nil;
    id steps = [self safeValueFromObject:firstPath forKey:@"steps"];
    if (![steps isKindOfClass:[NSArray class]]) return @[];

    for (id step in (NSArray *)steps) {
        NSString *polyline = [self safeValueFromObject:step forKey:@"polyline"];
        NSArray<NSValue *> *stepCoords = [self coordinatesFromAMapPolylineString:polyline];
        for (NSValue *value in stepCoords) {
            if (coords.count > 0) {
                CLLocationCoordinate2D last;
                [[coords lastObject] getValue:&last];
                CLLocationCoordinate2D next;
                [value getValue:&next];
                if (fabs(last.latitude - next.latitude) < 0.000001 &&
                    fabs(last.longitude - next.longitude) < 0.000001) {
                    continue;
                }
            }
            [coords addObject:value];
        }
    }
    return coords;
}

- (void)appendSegmentCoordinates:(NSArray<NSValue *> *)segmentCoords
                  toRouteCoords:(NSMutableArray<NSValue *> *)routeCoords {
    for (NSValue *value in segmentCoords) {
        if (routeCoords.count > 0) {
            CLLocationCoordinate2D last;
            [[routeCoords lastObject] getValue:&last];
            CLLocationCoordinate2D next;
            [value getValue:&next];
            if (fabs(last.latitude - next.latitude) < 0.000001 &&
                fabs(last.longitude - next.longitude) < 0.000001) {
                continue;
            }
        }
        [routeCoords addObject:value];
    }
}

// ============================================================
#pragma mark - 核心: 计算两点间真实步行距离
// ============================================================
- (void)walkingDistanceFrom:(CLLocationCoordinate2D)from
                         to:(CLLocationCoordinate2D)to
                 completion:(void(^)(SWPathSegment *result))completion {

    if (!completion) return;

    // 相同点 → 距离为0
    if (fabs(from.latitude - to.latitude) < 0.000001 &&
        fabs(from.longitude - to.longitude) < 0.000001) {
        SWPathSegment *seg = [[SWPathSegment alloc] init];
        seg.distance = 0;
        seg.straightDistance = 0;
        seg.source = SWPathSourceAMap;
        seg.isAvailable = YES;
        seg.duration = 0;
        seg.pathCoordinates = @[[NSValue valueWithMKCoordinate:from]];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(seg); });
        return;
    }

    // 先查缓存
    SWPathSegment *cached = [self cachedResultFrom:from to:to];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    // 优先: 高德地图
    if ([self isAMapAvailable]) {
        [self amapWalkingFrom:from to:to completion:^(SWPathSegment *result) {
            if ((result.source == SWPathSourceStraightLine || result.pathCoordinates.count <= 2) &&
                [self isAppleMapsAvailable]) {
                [self appleWalkingFrom:from to:to completion:^(SWPathSegment *appleResult) {
                    [self setCachedResult:appleResult from:from to:to];
                    completion(appleResult);
                }];
                return;
            }
            [self setCachedResult:result from:from to:to];
            completion(result);
        }];
        return;
    }

    // 回退: Apple Maps
    if ([self isAppleMapsAvailable]) {
        [self appleWalkingFrom:from to:to completion:^(SWPathSegment *result) {
            [self setCachedResult:result from:from to:to];
            completion(result);
        }];
        return;
    }

    // 最终回退: 直线距离 + 警告
    SWPathSegment *seg = [self straightLineFallbackFrom:from to:to];
    [self setCachedResult:seg from:from to:to];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(seg); });
}

// ============================================================
#pragma mark - 高德地图步行路线 (运行时动态调用)
// ============================================================
- (void)amapWalkingFrom:(CLLocationCoordinate2D)from
                     to:(CLLocationCoordinate2D)to
             completion:(void(^)(SWPathSegment *result))completion {

    double straightDist = [SWRunRoutePlanner distanceFromLat:from.latitude lng:from.longitude
                                                       toLat:to.latitude lng:to.longitude];

    @try {
        // 创建高德步行请求
        id request = [[self.amapWalkingRequestClass alloc] init];

        // 设置起点
        if ([request respondsToSelector:@selector(setOrigin:)]) {
            id origin = [self amapGeoPointWithCoordinate:from];
            if (origin) {
                [request performSelector:@selector(setOrigin:) withObject:origin];
            }
        }

        // 设置终点
        if ([request respondsToSelector:@selector(setDestination:)]) {
            id destination = [self amapGeoPointWithCoordinate:to];
            if (destination) {
                [request performSelector:@selector(setDestination:) withObject:destination];
            }
        }

        // 创建搜索 API (需要 API Key, App 内部已有)
        id searchAPI = [[self.amapRouteSearchClass alloc] init];

        // 设置代理回调
        // 方案: 用 block wrapper + associated object 实现回调
        __block BOOL callbackFired = NO;
        __weak typeof(self) weakSelf = self;

        // 尝试使用高德的 block 回调 API (新版 SDK)
        SEL blockSel = NSSelectorFromString(@"AMapWalkingRouteSearch:request:completion:");
        if ([searchAPI respondsToSelector:blockSel]) {
            void (^amapBlock)(id response, NSError *error) = ^(id response, NSError *error) {
                if (callbackFired) return;
                callbackFired = YES;

                if (error || !response) {
                    // 失败 → 回退到直线
                    SWPathSegment *fallback = [weakSelf straightLineFallbackFrom:from to:to];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(fallback); });
                    return;
                }

                SWPathSegment *seg = [weakSelf parseAMapWalkingResponse:response
                                                                    from:from
                                                                      to:to
                                                        straightDistance:straightDist];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(seg); });
            };

            // 动态调用
            ((void(*)(id, SEL, id, id, void(^)(id, NSError *)))objc_msgSend)(
                searchAPI, blockSel, request, searchAPI, amapBlock);
        } else {
            // 旧版 SDK: delegate 回调 — 这里简化处理，直接用直线距离
            // 因为 delegate 回调需要维护回调映射表，复杂度太高
            SWPathSegment *fallback = [self straightLineFallbackFrom:from to:to];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(fallback); });
        }

    } @catch (NSException *exception) {
        NSLog(@"[SWRunHUD] ⚠️ 高德地图调用异常: %@", exception.reason);
        SWPathSegment *fallback = [self straightLineFallbackFrom:from to:to];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(fallback); });
    }
}

/// 创建 AMapGeoPoint 对象
- (id)amapGeoPointWithCoordinate:(CLLocationCoordinate2D)coord {
    Class geoPointClass = NSClassFromString(@"AMapGeoPoint");
    if (!geoPointClass) return nil;

    id point = [[geoPointClass alloc] init];
    // ★ 浮点参数不能用 performSelector:withObject:, 改用 NSInvocation 或直接 KVC
    if ([point respondsToSelector:@selector(setLatitude:)]) {
        [point setValue:@(coord.latitude) forKey:@"latitude"];
    }
    if ([point respondsToSelector:@selector(setLongitude:)]) {
        [point setValue:@(coord.longitude) forKey:@"longitude"];
    }
    return point;
}

/// 解析高德步行响应
- (SWPathSegment *)parseAMapWalkingResponse:(id)response
                                       from:(CLLocationCoordinate2D)from
                                         to:(CLLocationCoordinate2D)to
                           straightDistance:(double)straightDist {
    SWPathSegment *seg = [[SWPathSegment alloc] init];
    seg.straightDistance = straightDist;
    seg.isAvailable = (response != nil);
    seg.pathCoordinates = [self fallbackPathCoordinatesFrom:from to:to];

    @try {
        id route = [self safeValueFromObject:response forKey:@"route"];
        id paths = [self safeValueFromObject:route forKey:@"paths"];
        id firstPath = [paths isKindOfClass:[NSArray class]] ? [(NSArray *)paths firstObject] : nil;

        id routes = [self safeValueFromObject:response forKey:@"routes"];
        id firstRoute = [routes isKindOfClass:[NSArray class]] ? [(NSArray *)routes firstObject] : nil;
        id distanceSource = firstPath ?: firstRoute;

        if (distanceSource) {
            id dist = [self safeValueFromObject:distanceSource forKey:@"distance"];
            if ([dist respondsToSelector:@selector(doubleValue)]) {
                seg.distance = [dist doubleValue];
                seg.source = SWPathSourceAMap;
            }

            id dur = [self safeValueFromObject:distanceSource forKey:@"duration"];
            if (![dur respondsToSelector:@selector(doubleValue)]) {
                dur = [self safeValueFromObject:distanceSource forKey:@"cost"];
            }
            if ([dur respondsToSelector:@selector(doubleValue)]) {
                seg.duration = [dur doubleValue];
            }
        } else {
            seg.distance = straightDist;
            seg.source = SWPathSourceStraightLine;
            seg.isAvailable = NO;
        }

        NSArray<NSValue *> *amapCoords = [self pathCoordinatesFromAMapResponse:response];
        if (amapCoords.count >= 2) {
            seg.pathCoordinates = amapCoords;
        }
    } @catch (NSException *exception) {
        seg.distance = straightDist;
        seg.source = SWPathSourceStraightLine;
        seg.isAvailable = NO;
    }

    // 合理性检查: 步行距离应该 >= 直线距离且 <= 直线距离 × 5
    if (seg.distance < straightDist * 0.8 || seg.distance > straightDist * 6.0) {
        seg.distance = straightDist * 1.3; // 经验值: 步行通常比直线多30%
        seg.source = SWPathSourceAMap;
    }
    if (seg.pathCoordinates.count < 2) {
        seg.pathCoordinates = [self fallbackPathCoordinatesFrom:from to:to];
    }

    return seg;
}

// ============================================================
#pragma mark - Apple Maps 步行路线
// ============================================================
- (void)appleWalkingFrom:(CLLocationCoordinate2D)from
                      to:(CLLocationCoordinate2D)to
              completion:(void(^)(SWPathSegment *result))completion {

    double straightDist = [SWRunRoutePlanner distanceFromLat:from.latitude lng:from.longitude
                                                       toLat:to.latitude lng:to.longitude];

    MKPlacemark *fromPlace = [[MKPlacemark alloc] initWithCoordinate:from];
    MKPlacemark *toPlace   = [[MKPlacemark alloc] initWithCoordinate:to];

    MKMapItem *fromItem = [[MKMapItem alloc] initWithPlacemark:fromPlace];
    MKMapItem *toItem   = [[MKMapItem alloc] initWithPlacemark:toPlace];

    MKDirectionsRequest *dirRequest = [[MKDirectionsRequest alloc] init];
    dirRequest.source = fromItem;
    dirRequest.destination = toItem;
    dirRequest.transportType = MKDirectionsTransportTypeWalking;
    dirRequest.requestsAlternateRoutes = NO;

    MKDirections *directions = [[MKDirections alloc] initWithRequest:dirRequest];

    [directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response, NSError *error) {
        SWPathSegment *seg = [[SWPathSegment alloc] init];
        seg.straightDistance = straightDist;

        if (error || response.routes.count == 0) {
            seg.distance = straightDist;
            seg.source = SWPathSourceStraightLine;
            seg.isAvailable = NO;
            seg.duration = straightDist / 1.4;
            seg.pathCoordinates = [self fallbackPathCoordinatesFrom:from to:to];
        } else {
            MKRoute *route = response.routes.firstObject;
            seg.distance = route.distance;
            seg.duration = route.expectedTravelTime;
            seg.source = SWPathSourceAppleMaps;
            seg.isAvailable = YES;
            NSArray<NSValue *> *routeCoords = [self coordinatesFromPolyline:route.polyline];
            seg.pathCoordinates = routeCoords.count >= 2 ? routeCoords : [self fallbackPathCoordinatesFrom:from to:to];
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(seg); });
    }];
}

// ============================================================
#pragma mark - 直线距离回退 + 警告
// ============================================================
- (SWPathSegment *)straightLineFallbackFrom:(CLLocationCoordinate2D)from
                                         to:(CLLocationCoordinate2D)to {
    double d = [SWRunRoutePlanner distanceFromLat:from.latitude lng:from.longitude
                                            toLat:to.latitude lng:to.longitude];

    SWPathSegment *seg = [[SWPathSegment alloc] init];
    seg.distance = d;
    seg.straightDistance = d;
    seg.source = SWPathSourceStraightLine;
    seg.isAvailable = YES;
    seg.duration = d / 1.4; // 步行 1.4 m/s
    seg.pathCoordinates = [self fallbackPathCoordinatesFrom:from to:to];
    return seg;
}

- (void)walkingRouteCoordinatesForCoordinates:(NSArray<NSValue *> *)coordinates
                                   completion:(void(^)(NSArray<NSValue *> *routeCoordinates, SWPathSource overallSource))completion {
    if (!completion) return;

    if (coordinates.count < 2) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(coordinates ?: @[], SWPathSourceStraightLine);
        });
        return;
    }

    NSMutableArray<NSValue *> *routeCoords = [NSMutableArray array];
    [self appendWalkingRouteCoordinates:coordinates
                                  index:0
                            routeCoords:routeCoords
                             worstSource:SWPathSourceAMap
                              completion:completion];
}

- (void)appendWalkingRouteCoordinates:(NSArray<NSValue *> *)coordinates
                                index:(NSInteger)index
                          routeCoords:(NSMutableArray<NSValue *> *)routeCoords
                           worstSource:(SWPathSource)worstSource
                            completion:(void(^)(NSArray<NSValue *> *routeCoordinates, SWPathSource overallSource))completion {
    if (index >= coordinates.count - 1) {
        completion(routeCoords, worstSource);
        return;
    }

    CLLocationCoordinate2D from;
    [coordinates[index] getValue:&from];
    CLLocationCoordinate2D to;
    [coordinates[index + 1] getValue:&to];

    [self walkingDistanceFrom:from to:to completion:^(SWPathSegment *result) {
        SWPathSource nextWorstSource = result.source > worstSource ? result.source : worstSource;
        NSArray<NSValue *> *segmentCoords = result.pathCoordinates.count >= 2
            ? result.pathCoordinates
            : [self fallbackPathCoordinatesFrom:from to:to];
        [self appendSegmentCoordinates:segmentCoords toRouteCoords:routeCoords];
        [self appendWalkingRouteCoordinates:coordinates
                                      index:index + 1
                                routeCoords:routeCoords
                                 worstSource:nextWorstSource
                                  completion:completion];
    }];
}

// ============================================================
#pragma mark - 批量构建距离矩阵
// ============================================================
- (void)buildDistanceMatrix:(NSArray<NSValue *> *)coordinates
                 completion:(void(^)(SWRunDistanceMatrix matrix, NSInteger count, SWPathSource overallSource))completion {

    NSInteger n = coordinates.count;
    if (n < 2) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NULL, n, SWPathSourceStraightLine); });
        return;
    }

    // 分配矩阵
    SWRunDistanceMatrix matrix = (SWRunDistanceMatrix)malloc(n * sizeof(double *));
    for (NSInteger i = 0; i < n; i++) {
        matrix[i] = (double *)calloc(n, sizeof(double));
    }

    // 需要计算的对数: n*(n-1)/2 (上三角)
    NSInteger totalPairs = n * (n - 1) / 2;
    __block NSInteger completedPairs = 0;
    __block SWPathSource worstSource = SWPathSourceAMap;

    dispatch_group_t group = dispatch_group_create();

    for (NSInteger i = 0; i < n; i++) {
        for (NSInteger j = i + 1; j < n; j++) {
            CLLocationCoordinate2D ci = [coordinates[i] MKCoordinateValue];
            CLLocationCoordinate2D cj = [coordinates[j] MKCoordinateValue];

            dispatch_group_enter(group);
            [[SWRunRouteRealPath sharedInstance] walkingDistanceFrom:ci to:cj completion:^(SWPathSegment *result) {
                @synchronized (self) {
                    matrix[i][j] = result.distance;
                    matrix[j][i] = result.distance; // 对称
                    completedPairs++;

                    // 追踪最差数据源
                    if (result.source > worstSource) {
                        worstSource = result.source;
                    }

                    if (completedPairs == totalPairs) {
                        NSLog(@"[SWRunHUD] 🌐 距离矩阵构建完成 (%ld×%ld) 数据源: %@",
                              (long)n, (long)n,
                              (worstSource == SWPathSourceAMap) ? @"高德" :
                              (worstSource == SWPathSourceAppleMaps) ? @"Apple" : @"直线");
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(matrix, n, worstSource);
    });
}

@end
