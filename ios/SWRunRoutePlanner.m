//
//  SWRunRoutePlanner.m
//  SWRunCheckpointHUD
//
//  路线规划实现 - Haversine 距离 + TSP 全排列搜索
//

#import "SWRunRoutePlanner.h"
#import "SWRunFloatingView.h" // 复用 SWRunCheckpoint 定义
#import "SWRunRouteRealPath.h"
#import <MapKit/MapKit.h>
#import <math.h>

// ============================================================
#pragma mark - SWRunRoutePlan 实现
// ============================================================
@implementation SWRunRoutePlan

- (NSString *)summaryString {
    NSMutableString *str = [NSMutableString string];

    // 数据源标签
    if (self.dataSourceDesc.length > 0) {
        [str appendFormat:@"%@\n", self.dataSourceDesc];
    }

    [str appendFormat:@"📐 最优路径: "];
    for (NSInteger i = 0; i < self.optimalOrder.count; i++) {
        [str appendFormat:@"%ld", (long)[self.optimalOrder[i] integerValue] + 1];
        if (i < self.optimalOrder.count - 1) [str appendString:@" → "];
    }

    [str appendFormat:@"\n📏 最优距离: %.0f 米", self.optimalDistance];
    [str appendFormat:@"\n📏 原定距离: %.0f 米", self.originalDistance];

    if (self.savedDistance > 1.0) {
        [str appendFormat:@"\n⚡ 节省距离: %.0f 米", self.savedDistance];
        [str appendFormat:@"\n⏱ 节省时间: %.0f 秒", self.savedTimeSeconds];
    }

    [str appendFormat:@"\n🕐 预计耗时: %.1f 分钟", self.estimatedMinutes];

    if (self.nextTargetIndex >= 0 && self.nextTargetIndex < 999) {
        [str appendFormat:@"\n🎯 下一个点位: 第 %ld 个", (long)(self.nextTargetIndex + 1)];
    }

    if (!self.usesRealPath) {
        [str appendString:@"\n⚠️ 当前为直线距离(可能穿墙过河!)"];
    }

    return str;
}

@end

// ============================================================
#pragma mark - SWRunRoutePlanner 实现
// ============================================================
@interface SWRunRoutePlanner ()

/// 预计算的坐标缓存 (CLLocationCoordinate2D 数组)
@property (nonatomic, strong) NSMutableArray<NSValue *> *coordinates;
/// 距离矩阵 [n][n]
@property (nonatomic, assign) double **distMatrix;
/// 点位数量
@property (nonatomic, assign) NSInteger pointCount;

- (void)includeMissingCheckpointsInPlan:(SWRunRoutePlan *)plan
                            checkpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
                           fromLatitude:(double)startLat
                          fromLongitude:(double)startLng;

@end

static BOOL SWRunHasRouteStart(double lat, double lng) {
    return !(lat == 0 && lng == 0);
}

@implementation SWRunRoutePlanner

// ============================================================
#pragma mark - 单例
// ============================================================
+ (instancetype)sharedInstance {
    static SWRunRoutePlanner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SWRunRoutePlanner alloc] init];
    });
    return instance;
}

// ============================================================
#pragma mark - Haversine 距离公式
// ============================================================
+ (double)distanceFromLat:(double)lat1 lng:(double)lng1
                    toLat:(double)lat2 lng:(double)lng2 {
    if (lat1 == 0 && lng1 == 0) return 0;
    if (lat2 == 0 && lng2 == 0) return 0;

    double R = 6371000.0; // 地球半径 (米)

    double dLat = (lat2 - lat1) * M_PI / 180.0;
    double dLng = (lng2 - lng1) * M_PI / 180.0;

    double a = sin(dLat / 2.0) * sin(dLat / 2.0) +
               cos(lat1 * M_PI / 180.0) * cos(lat2 * M_PI / 180.0) *
               sin(dLng / 2.0) * sin(dLng / 2.0);

    double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));

    return R * c;
}

// ============================================================
#pragma mark - 核心: 最优路径计算
// ============================================================
- (SWRunRoutePlan *)planOptimalRoute:(NSArray<SWRunCheckpoint *> *)checkpoints
                       fromLatitude:(double)currentLat
                      fromLongitude:(double)currentLng {

    if (checkpoints.count < 2) {
        // 点数不足，返回原顺序
        return [self planFixedOnlyRoute:checkpoints];
    }

    NSInteger n = checkpoints.count;
    self.pointCount = n;

    // === 第一步: 构建距离矩阵 ===
    [self buildDistanceMatrix:checkpoints];

    // === 第二步: 提取必经点索引 ===
    NSMutableArray<NSNumber *> *fixedIndices = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        if (checkpoints[i].isFixed) {
            [fixedIndices addObject:@(i)];
        }
    }

    // === 第三步: 对必经点做 TSP 全排列搜索 ===
    NSInteger m = fixedIndices.count;

    SWRunRoutePlan *plan = [[SWRunRoutePlan alloc] init];

    if (m >= 2) {
        // 有2个及以上必经点 → TSP 搜索最优访问顺序
        [self solveTSPForIndices:fixedIndices
               allCheckpoints:checkpoints
                fromLatitude:currentLat
               fromLongitude:currentLng
                         plan:plan];
    } else if (m == 1) {
        // 只有1个必经点 → 直接计算距离
        [self singleFixedRoute:fixedIndices
                allCheckpoints:checkpoints
                 fromLatitude:currentLat
                fromLongitude:currentLng
                          plan:plan];
    } else {
        // 没有必经点 → 使用原顺序计算
        [self originalOrderRoute:checkpoints
                    fromLatitude:currentLat
                   fromLongitude:currentLng
                             plan:plan];
    }

    [self includeMissingCheckpointsInPlan:plan
                              checkpoints:checkpoints
                             fromLatitude:currentLat
                            fromLongitude:currentLng];

    // === 第四步: 计算原定顺序的总距离 (用于对比) ===
    [self calculateOriginalDistance:checkpoints plan:plan];

    // === 第五步: 计算统计信息 ===
    [self finalizePlan:plan checkpoints:checkpoints m:m];

    // === 清理 ===
    [self freeDistanceMatrix];

    return plan;
}

// ============================================================
#pragma mark - 遍历必经点模式
// ============================================================
- (SWRunRoutePlan *)planFixedOnlyRoute:(NSArray<SWRunCheckpoint *> *)checkpoints {
    // 使用原顺序，但只统计必经点
    SWRunRoutePlan *plan = [[SWRunRoutePlan alloc] init];

    NSMutableArray *fixedOnly = [NSMutableArray array];
    double totalDist = 0;
    double prevLat = 0, prevLng = 0;
    BOOL hasPrev = NO;
    NSMutableArray *segments = [NSMutableArray array];

    for (NSInteger i = 0; i < checkpoints.count; i++) {
        SWRunCheckpoint *cp = checkpoints[i];
        if (cp.isFixed) {
            [fixedOnly addObject:@(i)];

            if (hasPrev) {
                double d = [SWRunRoutePlanner distanceFromLat:prevLat lng:prevLng
                                                        toLat:cp.latitude lng:cp.longitude];
                totalDist += d;
                [segments addObject:@(d)];
            }
            prevLat = cp.latitude;
            prevLng = cp.longitude;
            hasPrev = YES;
        }
    }

    plan.optimalOrder = fixedOnly;
    plan.optimalDistance = totalDist;
    plan.segmentDistances = segments;

    return plan;
}

// ============================================================
#pragma mark - ★ 异步版本: 使用真实步行路径
// ============================================================
- (void)planOptimalRouteAsync:(NSArray<SWRunCheckpoint *> *)checkpoints
                    completion:(void(^)(SWRunRoutePlan *plan))completion {

    if (!completion) return;

    NSInteger n = checkpoints.count;
    if (n < 2) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([self planFixedOnlyRoute:checkpoints]);
        });
        return;
    }

    // 构建坐标数组
    NSMutableArray<NSValue *> *coords = [NSMutableArray arrayWithCapacity:n];
    for (SWRunCheckpoint *cp in checkpoints) {
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(cp.latitude, cp.longitude);
        [coords addObject:[NSValue valueWithMKCoordinate:coord]];
    }

    NSLog(@"[SWRunHUD] 🔍 正在获取真实步行路径 (共 %ld 个点)...", (long)n);

    // 调用真实路径计算器构建距离矩阵
    [[SWRunRouteRealPath sharedInstance] buildDistanceMatrix:coords completion:^(double **matrix, NSInteger count, SWPathSource overallSource) {

        // 保存矩阵到实例变量
        self.pointCount = count;
        self.distMatrix = matrix;

        // 提取必经点索引
        NSMutableArray<NSNumber *> *fixedIndices = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) {
            if (checkpoints[i].isFixed) {
                [fixedIndices addObject:@(i)];
            }
        }
        NSInteger m = fixedIndices.count;

        SWRunRoutePlan *plan = [[SWRunRoutePlan alloc] init];

        // 数据源描述
        switch (overallSource) {
            case SWPathSourceAMap:
                plan.dataSourceDesc = @"🗺 高德地图真实步行路径";
                plan.usesRealPath = YES;
                break;
            case SWPathSourceAppleMaps:
                plan.dataSourceDesc = @"🍎 Apple Maps 真实步行路径";
                plan.usesRealPath = YES;
                break;
            case SWPathSourceStraightLine:
                plan.dataSourceDesc = @"⚠️ 直线距离(无地图,可能穿墙过河!)";
                plan.usesRealPath = NO;
                break;
        }

        if (m >= 2) {
            [self solveTSPForIndices:fixedIndices
                   allCheckpoints:checkpoints
                    fromLatitude:0
                   fromLongitude:0
                             plan:plan];
        } else if (m == 1) {
            [self singleFixedRoute:fixedIndices
                    allCheckpoints:checkpoints
                     fromLatitude:0
                    fromLongitude:0
                              plan:plan];
        } else {
            [self originalOrderRoute:checkpoints
                        fromLatitude:0
                       fromLongitude:0
                                 plan:plan];
        }

        [self includeMissingCheckpointsInPlan:plan
                                  checkpoints:checkpoints
                                 fromLatitude:0
                                fromLongitude:0];

        // 原定距离
        [self calculateOriginalDistance:checkpoints plan:plan];

        // 修正速度: 真实步行约 1.4 m/s
        double speed = plan.usesRealPath ? 1.4 : 2.5;
        plan.savedDistance = plan.originalDistance - plan.optimalDistance;
        if (plan.savedDistance < 0) plan.savedDistance = 0;
        plan.estimatedMinutes = plan.optimalDistance / speed / 60.0;
        plan.savedTimeSeconds = plan.savedDistance / speed;

        // 下一个目标
        plan.nextTargetIndex = -1;
        for (NSNumber *idxNum in plan.optimalOrder) {
            NSInteger idx = [idxNum integerValue];
            if (!checkpoints[idx].isPassed) {
                plan.nextTargetIndex = idx;
                break;
            }
        }

        // 清理
        [self freeDistanceMatrix];

        NSLog(@"[SWRunHUD] ✅ 真实路径规划完成 (%@, %.0fm)",
              plan.usesRealPath ? @"真实步行" : @"直线估算", plan.optimalDistance);

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(plan);
        });
    }];
}

// ============================================================
#pragma mark - 内部方法
// ============================================================

/// 构建距离矩阵
- (void)buildDistanceMatrix:(NSArray<SWRunCheckpoint *> *)checkpoints {
    NSInteger n = checkpoints.count;

    // 分配矩阵
    self.distMatrix = (double **)malloc(n * sizeof(double *));
    for (NSInteger i = 0; i < n; i++) {
        self.distMatrix[i] = (double *)malloc(n * sizeof(double));
    }

    // 计算每对点之间的距离
    for (NSInteger i = 0; i < n; i++) {
        for (NSInteger j = 0; j < n; j++) {
            if (i == j) {
                self.distMatrix[i][j] = 0;
            } else {
                self.distMatrix[i][j] = [SWRunRoutePlanner
                    distanceFromLat:checkpoints[i].latitude
                                lng:checkpoints[i].longitude
                              toLat:checkpoints[j].latitude
                                lng:checkpoints[j].longitude];
            }
        }
    }
}

/// 释放距离矩阵
- (void)freeDistanceMatrix {
    if (!self.distMatrix) return;
    for (NSInteger i = 0; i < self.pointCount; i++) {
        free(self.distMatrix[i]);
    }
    free(self.distMatrix);
    self.distMatrix = NULL;
}

/// TSP 全排列搜索最优访问顺序 (对必经点)
- (void)solveTSPForIndices:(NSArray<NSNumber *> *)fixedIndices
             allCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
              fromLatitude:(double)startLat
             fromLongitude:(double)startLng
                       plan:(SWRunRoutePlan *)plan {

    NSInteger m = fixedIndices.count;
    NSMutableArray *indices = [fixedIndices mutableCopy];

    // 全排列搜索
    NSMutableArray *bestOrder = nil;
    double bestDist = DBL_MAX;
    NSMutableArray *bestSegments = nil;

    // 使用 Heap's Algorithm 生成全排列
    NSMutableArray *c = [NSMutableArray arrayWithCapacity:m];
    for (NSInteger i = 0; i < m; i++) [c addObject:@(0)];

    // 评估初始排列
    {
        double dist = 0;
        NSMutableArray *segs = [NSMutableArray array];
        // 从当前位置到第一个点
        double d = SWRunHasRouteStart(startLat, startLng)
            ? [SWRunRoutePlanner distanceFromLat:startLat lng:startLng
                                           toLat:checkpoints[[indices[0] integerValue]].latitude
                                             lng:checkpoints[[indices[0] integerValue]].longitude]
            : 0;
        dist += d;
        [segs addObject:@(d)];

        for (NSInteger i = 1; i < m; i++) {
            d = self.distMatrix[[indices[i-1] integerValue]][[indices[i] integerValue]];
            dist += d;
            [segs addObject:@(d)];
        }

        if (dist < bestDist) {
            bestDist = dist;
            bestOrder = [indices mutableCopy];
            bestSegments = [segs mutableCopy];
        }
    }

    // Heap's Algorithm
    NSInteger i = 0;
    while (i < m) {
        if ([c[i] integerValue] < i) {
            if (i % 2 == 0) {
                [indices exchangeObjectAtIndex:0 withObjectAtIndex:i];
            } else {
                [indices exchangeObjectAtIndex:[c[i] integerValue] withObjectAtIndex:i];
            }

            // 评估当前排列
            double dist = 0;
            NSMutableArray *segs = [NSMutableArray array];
            double d = SWRunHasRouteStart(startLat, startLng)
                ? [SWRunRoutePlanner distanceFromLat:startLat lng:startLng
                                               toLat:checkpoints[[indices[0] integerValue]].latitude
                                                 lng:checkpoints[[indices[0] integerValue]].longitude]
                : 0;
            dist += d;
            [segs addObject:@(d)];

            for (NSInteger k = 1; k < m; k++) {
                d = self.distMatrix[[indices[k-1] integerValue]][[indices[k] integerValue]];
                dist += d;
                [segs addObject:@(d)];
            }

            if (dist < bestDist) {
                bestDist = dist;
                bestOrder = [indices mutableCopy];
                bestSegments = [segs mutableCopy];
            }

            c[i] = @([c[i] integerValue] + 1);
            i = 0;
        } else {
            c[i] = @(0);
            i++;
        }
    }

    plan.optimalOrder = bestOrder;
    plan.optimalDistance = bestDist;
    plan.segmentDistances = bestSegments;
}

/// 只有1个必经点
- (void)singleFixedRoute:(NSArray<NSNumber *> *)fixedIndices
          allCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
           fromLatitude:(double)startLat
          fromLongitude:(double)startLng
                    plan:(SWRunRoutePlan *)plan {

    NSInteger idx = [fixedIndices.firstObject integerValue];
    double d = SWRunHasRouteStart(startLat, startLng)
        ? [SWRunRoutePlanner distanceFromLat:startLat lng:startLng
                                       toLat:checkpoints[idx].latitude
                                         lng:checkpoints[idx].longitude]
        : 0;

    plan.optimalOrder = fixedIndices;
    plan.optimalDistance = d;
    plan.segmentDistances = @[@(d)];
}

/// 没有必经点 → 原顺序
- (void)originalOrderRoute:(NSArray<SWRunCheckpoint *> *)checkpoints
              fromLatitude:(double)startLat
             fromLongitude:(double)startLng
                       plan:(SWRunRoutePlan *)plan {

    NSInteger n = checkpoints.count;
    NSMutableArray *order = [NSMutableArray array];
    NSMutableArray *segs = [NSMutableArray array];
    double totalDist = 0;

    for (NSInteger i = 0; i < n; i++) {
        [order addObject:@(i)];
        if (i == 0) {
            double d = SWRunHasRouteStart(startLat, startLng)
                ? [SWRunRoutePlanner distanceFromLat:startLat lng:startLng
                                               toLat:checkpoints[i].latitude
                                                 lng:checkpoints[i].longitude]
                : 0;
            totalDist += d;
            [segs addObject:@(d)];
        } else {
            double d = self.distMatrix[i-1][i];
            totalDist += d;
            [segs addObject:@(d)];
        }
    }

    plan.optimalOrder = order;
    plan.optimalDistance = totalDist;
    plan.segmentDistances = segs;
}

/// 将普通点位也插入模拟访问顺序，保证显示出来的检测点都会被路径经过
- (void)includeMissingCheckpointsInPlan:(SWRunRoutePlan *)plan
                            checkpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
                           fromLatitude:(double)startLat
                          fromLongitude:(double)startLng {
    NSInteger n = checkpoints.count;
    if (n == 0) return;

    NSMutableArray<NSNumber *> *order = plan.optimalOrder ? [plan.optimalOrder mutableCopy] : [NSMutableArray array];
    NSMutableSet<NSNumber *> *included = [NSMutableSet setWithArray:order];

    for (NSInteger i = 0; i < n; i++) {
        NSNumber *idxNum = @(i);
        if ([included containsObject:idxNum]) continue;

        if (order.count == 0) {
            [order addObject:idxNum];
            [included addObject:idxNum];
            continue;
        }

        NSInteger bestInsertPos = order.count;
        double bestDelta = DBL_MAX;
        for (NSInteger pos = 0; pos <= order.count; pos++) {
            NSInteger before = pos == 0 ? -1 : [order[pos - 1] integerValue];
            NSInteger after = pos == order.count ? -1 : [order[pos] integerValue];

            double addDist = 0;
            double oldDist = 0;

            if (before >= 0) {
                addDist += self.distMatrix[before][i];
            } else if (SWRunHasRouteStart(startLat, startLng)) {
                addDist += [SWRunRoutePlanner distanceFromLat:startLat
                                                          lng:startLng
                                                        toLat:checkpoints[i].latitude
                                                          lng:checkpoints[i].longitude];
            }

            if (after >= 0) {
                addDist += self.distMatrix[i][after];
                if (before >= 0) {
                    oldDist += self.distMatrix[before][after];
                } else if (SWRunHasRouteStart(startLat, startLng)) {
                    oldDist += [SWRunRoutePlanner distanceFromLat:startLat
                                                              lng:startLng
                                                            toLat:checkpoints[after].latitude
                                                              lng:checkpoints[after].longitude];
                }
            }

            double delta = addDist - oldDist;
            if (delta < bestDelta) {
                bestDelta = delta;
                bestInsertPos = pos;
            }
        }

        [order insertObject:idxNum atIndex:bestInsertPos];
        [included addObject:idxNum];
    }

    double totalDist = 0;
    NSMutableArray<NSNumber *> *segments = [NSMutableArray array];
    for (NSInteger i = 0; i < order.count; i++) {
        NSInteger idx = [order[i] integerValue];
        double d = 0;
        if (i == 0) {
            d = SWRunHasRouteStart(startLat, startLng)
                ? [SWRunRoutePlanner distanceFromLat:startLat
                                               lng:startLng
                                             toLat:checkpoints[idx].latitude
                                               lng:checkpoints[idx].longitude]
                : 0;
        } else {
            NSInteger prev = [order[i - 1] integerValue];
            d = self.distMatrix[prev][idx];
        }
        totalDist += d;
        [segments addObject:@(d)];
    }

    plan.optimalOrder = order;
    plan.optimalDistance = totalDist;
    plan.segmentDistances = segments;
}

/// 计算原定顺序的距离
- (void)calculateOriginalDistance:(NSArray<SWRunCheckpoint *> *)checkpoints plan:(SWRunRoutePlan *)plan {
    NSInteger n = checkpoints.count;
    if (n < 2) return;

    NSMutableArray *origOrder = [NSMutableArray array];
    double origDist = 0;

    for (NSInteger i = 0; i < n; i++) {
        [origOrder addObject:@(i)];
    }

    for (NSInteger i = 1; i < n; i++) {
        origDist += self.distMatrix[i-1][i];
    }

    plan.originalOrder = origOrder;
    plan.originalDistance = origDist;
}

/// 完善规划结果统计
- (void)finalizePlan:(SWRunRoutePlan *)plan
        checkpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
                  m:(NSInteger)m {

    // 节省距离
    plan.savedDistance = plan.originalDistance - plan.optimalDistance;
    if (plan.savedDistance < 0) plan.savedDistance = 0;

    // 按 2.5 m/s (9 km/h 慢跑) 估算时间
    double speed = 2.5;
    plan.estimatedMinutes = plan.optimalDistance / speed / 60.0;
    plan.savedTimeSeconds = plan.savedDistance / speed;

    // 下一个目标: 找最优顺序中第一个未通过的必经点
    plan.nextTargetIndex = -1;
    for (NSNumber *idxNum in plan.optimalOrder) {
        NSInteger idx = [idxNum integerValue];
        if (!checkpoints[idx].isPassed) {
            plan.nextTargetIndex = idx;
            break;
        }
    }
}

@end
