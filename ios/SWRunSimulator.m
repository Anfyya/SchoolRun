//
//  SWRunSimulator.m
//  SWRunCheckpointHUD
//
//  步行路线模拟器实现
//  沿路径逐秒生成模拟 CLLocation, 模仿真实步行
//

#import "SWRunSimulator.h"
#import "SWRunFloatingView.h"
#import "SWRunRoutePlanner.h"
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>
#import <float.h>

// ============================================================
#pragma mark - SWSimulatedMotionData
// ============================================================
@implementation SWSimulatedMotionData

- (instancetype)init {
    self = [super init];
    if (self) {
        _stepLength = 0.76; // 180cm男生正常步长 (身高×0.42)
    }
    return self;
}

@end

// ============================================================
#pragma mark - 常量
// ============================================================
static double const kDefaultWalkingSpeed  = 1.4;  // m/s
static double const kSpeedVariation       = 0.15; // ±15%
static double const kLocationJitter       = 0.000003; // ~0.3m GPS 漂移
static double const kTickInterval         = 1.0;  // 每秒一个点
static double const kBaseAltitude         = 15.0; // 统一起跑海拔
static double const kNominalStepLength    = 0.76; // 用于距离反推步数
static double const kMinimumPathDistance  = 1100.0; // 路线距离下限

@interface SWRunSimulator ()

@property (nonatomic, readwrite) SWSimulatorState     state;
@property (nonatomic, readwrite) CLLocation          *currentLocation;
@property (nonatomic, readwrite) double               traveledDistance;
@property (nonatomic, readwrite) double               totalPathDistance;
@property (nonatomic, readwrite) double               elapsedSeconds;
@property (nonatomic, readwrite) NSDate              *simulationStartDate;
@property (nonatomic, readwrite) NSInteger             currentTargetIndex;
@property (nonatomic, readwrite) SWSimulatedMotionData *motionData;

/// 预生成的全部路径点数组 (CLLocation 数组)
@property (nonatomic, strong) NSMutableArray<CLLocation *> *pathPoints;
@property (nonatomic, strong) NSMutableArray<NSNumber *>   *pathCumulativeDistances;
/// 路径中的里程碑 (每个 checkpoint 对应的 pathPoints 索引)
@property (nonatomic, strong) NSMutableArray<NSNumber *>   *checkpointIndices;
/// 当前在 pathPoints 中的索引
@property (nonatomic, assign) NSInteger                    pathIndex;

/// 模拟定时器
@property (nonatomic, strong) NSTimer                     *tickTimer;
/// 基础步行速度
@property (nonatomic, assign) double                       walkingSpeed;

/// 回调 blocks
@property (nonatomic, copy)   SWSimulatorTickBlock        tickBlock;
@property (nonatomic, copy)   SWSimulatorCompleteBlock    completeBlock;

/// 原始点位信息
@property (nonatomic, strong) NSArray<SWRunCheckpoint *>  *checkpoints;
@property (nonatomic, strong) NSArray<NSNumber *>         *visitOrder;
@property (nonatomic, strong) CLLocation                  *startLocation;
@property (nonatomic, copy)   NSArray<NSValue *>          *routeCoordinates;
@property (nonatomic, assign) double                       nextFloorDistance;

- (void)resetMotionData;
- (CLLocation *)makeLocation:(double)lat
                         lng:(double)lng
                     heading:(double)heading
                       speed:(double)speed;
- (CLLocation *)locationAtDistance:(double)distance heading:(double *)headingOut speed:(double)speed;
- (void)updateMotionDataWithStepDistance:(double)stepDistance speed:(double)speed;
- (double)headingFrom:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to;
- (void)appendPathSegmentToLocation:(CLLocation *)endLoc totalDistance:(double *)totalDist;
- (void)appendMinimumDistanceRetraceIfNeeded:(double *)totalDist;
- (BOOL)locationLooksUsable:(CLLocation *)location;
- (void)appendRouteCoordinates:(NSArray<NSValue *> *)routeCoordinates totalDistance:(double *)totalDist;
- (void)rebuildCheckpointIndicesFromPath;

@end

@implementation SWRunSimulator

// ============================================================
#pragma mark - 单例
// ============================================================
+ (instancetype)sharedInstance {
    static SWRunSimulator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SWRunSimulator alloc] initInternal];
    });
    return instance;
}

- (instancetype)initInternal {
    self = [super init];
    if (self) {
        _state = SWSimulatorStateIdle;
        _walkingSpeed = kDefaultWalkingSpeed;
        _pathPoints = [NSMutableArray array];
        _pathCumulativeDistances = [NSMutableArray array];
        _checkpointIndices = [NSMutableArray array];
        _pathIndex = 0;
        _traveledDistance = 0;
        _totalPathDistance = 0;
        _elapsedSeconds = 0;
        _currentTargetIndex = -1;
        _motionData = [[SWSimulatedMotionData alloc] init];
        _nextFloorDistance = 200.0;
        [self resetMotionData];
    }
    return self;
}

// ============================================================
#pragma mark - 路径生成
// ============================================================

- (BOOL)locationLooksUsable:(CLLocation *)location {
    if (!location) return NO;
    CLLocationCoordinate2D coord = location.coordinate;
    return CLLocationCoordinate2DIsValid(coord) &&
           fabs(coord.latitude) > 0.000001 &&
           fabs(coord.longitude) > 0.000001;
}

- (void)appendPathSegmentToLocation:(CLLocation *)endLoc totalDistance:(double *)totalDist {
    if (!endLoc || self.pathPoints.count == 0 || !totalDist) return;

    CLLocation *startLoc = [self.pathPoints lastObject];
    double segmentDist = [startLoc distanceFromLocation:endLoc];
    double segmentTime = segmentDist / self.walkingSpeed;
    NSInteger steps = MAX(1, (NSInteger)round(segmentTime));

    double startLat = startLoc.coordinate.latitude;
    double startLng = startLoc.coordinate.longitude;
    double endLat   = endLoc.coordinate.latitude;
    double endLng   = endLoc.coordinate.longitude;

    for (NSInteger s = 1; s <= steps; s++) {
        double t = (double)s / (double)steps;
        double easedT = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2;
        double lat = startLat + (endLat - startLat) * easedT;
        double lng = startLng + (endLng - startLng) * easedT;

        if (s < steps) {
            lat += [self randomJitter];
            lng += [self randomJitter];
        }

        CLLocation *loc = [self makeLocation:lat lng:lng];
        CLLocation *prevLoc = [self.pathPoints lastObject];
        *totalDist += [prevLoc distanceFromLocation:loc];
        [self.pathPoints addObject:loc];
        [self.pathCumulativeDistances addObject:@(*totalDist)];
    }
}

- (void)appendMinimumDistanceRetraceIfNeeded:(double *)totalDist {
    if (!totalDist || *totalDist >= kMinimumPathDistance || self.pathPoints.count == 0) return;
    if (self.pathPoints.count < 2) return;

    NSArray<CLLocation *> *basePath = [self.pathPoints copy];
    NSInteger guard = 0;
    while (*totalDist < kMinimumPathDistance && guard < 8) {
        guard++;

        for (NSInteger i = (NSInteger)basePath.count - 2; i >= 0 && *totalDist < kMinimumPathDistance; i--) {
            CLLocation *loc = basePath[i];
            [self appendPathSegmentToLocation:loc totalDistance:totalDist];
        }

        for (NSInteger i = 1; i < basePath.count && *totalDist < kMinimumPathDistance; i++) {
            CLLocation *loc = basePath[i];
            [self appendPathSegmentToLocation:loc totalDistance:totalDist];
        }
    }
}

- (void)appendRouteCoordinates:(NSArray<NSValue *> *)routeCoordinates totalDistance:(double *)totalDist {
    if (!totalDist || routeCoordinates.count == 0) return;

    for (NSValue *value in routeCoordinates) {
        CLLocationCoordinate2D coord;
        [value getValue:&coord];
        if (!CLLocationCoordinate2DIsValid(coord) ||
            fabs(coord.latitude) < 0.000001 ||
            fabs(coord.longitude) < 0.000001) {
            continue;
        }

        CLLocation *loc = [self makeLocation:coord.latitude lng:coord.longitude];
        if (self.pathPoints.count == 0) {
            [self.pathPoints addObject:loc];
            [self.pathCumulativeDistances addObject:@(0)];
            continue;
        }

        CLLocation *lastLoc = [self.pathPoints lastObject];
        if ([lastLoc distanceFromLocation:loc] < 0.2) continue;
        [self appendPathSegmentToLocation:loc totalDistance:totalDist];
    }
}

- (void)rebuildCheckpointIndicesFromPath {
    [self.checkpointIndices removeAllObjects];
    if (self.pathPoints.count == 0 || self.visitOrder.count == 0) return;

    NSInteger searchStart = 0;
    for (NSNumber *idxNum in self.visitOrder) {
        NSInteger cpIdx = [idxNum integerValue];
        if (cpIdx < 0 || cpIdx >= self.checkpoints.count) continue;

        SWRunCheckpoint *cp = self.checkpoints[cpIdx];
        CLLocation *targetLoc = [[CLLocation alloc] initWithLatitude:cp.latitude longitude:cp.longitude];
        NSInteger bestIndex = searchStart;
        double bestDistance = DBL_MAX;

        for (NSInteger i = searchStart; i < self.pathPoints.count; i++) {
            double d = [self.pathPoints[i] distanceFromLocation:targetLoc];
            if (d < bestDistance) {
                bestDistance = d;
                bestIndex = i;
            }
        }

        [self.checkpointIndices addObject:@(bestIndex)];
        searchStart = MIN(bestIndex + 1, (NSInteger)self.pathPoints.count - 1);
    }
}

/// 根据检查点和访问顺序生成完整路径点序列
- (void)generatePathPoints {
    [self.pathPoints removeAllObjects];
    [self.pathCumulativeDistances removeAllObjects];
    [self.checkpointIndices removeAllObjects];

    if (self.visitOrder.count == 0) return;

    double totalDist = 0;
    BOOL hasRealStart = [self locationLooksUsable:self.startLocation];

    BOOL usedRouteCoordinates = NO;
    if (self.routeCoordinates.count >= 2) {
        [self appendRouteCoordinates:self.routeCoordinates totalDistance:&totalDist];
        if (self.pathPoints.count >= 2) {
            [self rebuildCheckpointIndicesFromPath];
            usedRouteCoordinates = YES;
        } else {
            [self.pathPoints removeAllObjects];
            [self.pathCumulativeDistances removeAllObjects];
            [self.checkpointIndices removeAllObjects];
            totalDist = 0;
        }
    }

    if (!usedRouteCoordinates) {
        if (hasRealStart) {
            [self.pathPoints addObject:self.startLocation];
            [self.pathCumulativeDistances addObject:@(0)];
        }

        for (NSInteger i = 0; i < self.visitOrder.count; i++) {
            NSInteger cpIdx = [self.visitOrder[i] integerValue];
            SWRunCheckpoint *cp = self.checkpoints[cpIdx];

            if (i == 0 && !hasRealStart) {
                // 第一个点: 直接添加
                CLLocation *loc = [self makeLocation:cp.latitude lng:cp.longitude];
                [self.pathPoints addObject:loc];
                [self.pathCumulativeDistances addObject:@(0)];
                [self.checkpointIndices addObject:@(self.pathPoints.count - 1)];
            } else {
                // 从真实起点或上一个 checkpoint 到当前 checkpoint 生成中间路径点
                CLLocation *endLoc   = [self makeLocation:cp.latitude lng:cp.longitude];
                [self appendPathSegmentToLocation:endLoc totalDistance:&totalDist];

                // 标记 checkpoint 位置
                [self.checkpointIndices addObject:@(self.pathPoints.count - 1)];
            }
        }
    }

    [self appendMinimumDistanceRetraceIfNeeded:&totalDist];

    self.totalPathDistance = totalDist;
    self.traveledDistance = 0;
    self.elapsedSeconds = 0;
    self.pathIndex = 0;
    self.nextFloorDistance = 200.0;
    [self resetMotionData];

    if (self.pathPoints.count > 0) {
        self.currentLocation = self.pathPoints[0];
    }

    // 设置初始目标
    [self updateCurrentTarget];

    NSLog(@"[SWRunHUD] 🛤 路径生成完成: %lu 个点, 总距离 %.0fm, 预计 %.0fs",
          (unsigned long)self.pathPoints.count, self.totalPathDistance,
          self.totalPathDistance / self.walkingSpeed);
}

/// 创建 CLLocation (带合理的时间戳和精度)
- (CLLocation *)makeLocation:(double)lat lng:(double)lng {
    return [self makeLocation:lat lng:lng heading:-1 speed:self.walkingSpeed];
}

- (CLLocation *)makeLocation:(double)lat
                         lng:(double)lng
                     heading:(double)heading
                       speed:(double)speed {
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(lat, lng);
    double horizontalAccuracy = 5.0 + fabs([self randomJitter]) * 30.0;
    double verticalAccuracy = 3.0;

    if (@available(iOS 13.4, *)) {
        return [[CLLocation alloc] initWithCoordinate:coordinate
                                             altitude:self.motionData.currentAltitude
                                   horizontalAccuracy:horizontalAccuracy
                                     verticalAccuracy:verticalAccuracy
                                               course:heading
                                       courseAccuracy:(heading >= 0 ? self.motionData.headingAccuracy : -1)
                                                speed:speed
                                        speedAccuracy:0.3
                                            timestamp:[NSDate date]];
    }

    return [[CLLocation alloc] initWithCoordinate:coordinate
                                         altitude:self.motionData.currentAltitude
                               horizontalAccuracy:horizontalAccuracy
                                 verticalAccuracy:verticalAccuracy
                                           course:heading
                                            speed:speed
                                         timestamp:[NSDate date]];
}

- (CLLocation *)locationAtDistance:(double)distance heading:(double *)headingOut speed:(double)speed {
    if (self.pathPoints.count == 0 || self.pathCumulativeDistances.count != self.pathPoints.count) {
        return nil;
    }

    if (distance <= 0 || self.pathPoints.count == 1) {
        CLLocation *first = self.pathPoints.firstObject;
        if (headingOut) *headingOut = self.motionData.currentHeading;
        return [self makeLocation:first.coordinate.latitude
                              lng:first.coordinate.longitude
                          heading:(headingOut ? *headingOut : self.motionData.currentHeading)
                            speed:speed];
    }

    double cappedDistance = MIN(distance, self.totalPathDistance);
    while (self.pathIndex + 1 < self.pathCumulativeDistances.count &&
           [self.pathCumulativeDistances[self.pathIndex + 1] doubleValue] <= cappedDistance) {
        self.pathIndex++;
    }

    if (self.pathIndex >= self.pathPoints.count - 1) {
        CLLocation *last = self.pathPoints.lastObject;
        if (headingOut) *headingOut = self.motionData.currentHeading;
        return [self makeLocation:last.coordinate.latitude
                              lng:last.coordinate.longitude
                          heading:(headingOut ? *headingOut : self.motionData.currentHeading)
                            speed:speed];
    }

    CLLocation *fromLoc = self.pathPoints[self.pathIndex];
    CLLocation *toLoc = self.pathPoints[self.pathIndex + 1];
    double fromDistance = [self.pathCumulativeDistances[self.pathIndex] doubleValue];
    double toDistance = [self.pathCumulativeDistances[self.pathIndex + 1] doubleValue];
    double span = MAX(toDistance - fromDistance, 0.001);
    double t = MIN(1.0, MAX(0, (cappedDistance - fromDistance) / span));

    double lat = fromLoc.coordinate.latitude + (toLoc.coordinate.latitude - fromLoc.coordinate.latitude) * t;
    double lng = fromLoc.coordinate.longitude + (toLoc.coordinate.longitude - fromLoc.coordinate.longitude) * t;
    double heading = [self headingFrom:fromLoc.coordinate to:toLoc.coordinate];
    if (headingOut) *headingOut = heading;
    return [self makeLocation:lat lng:lng heading:heading speed:speed];
}

/// 生成随机 GPS 漂移
- (double)randomJitter {
    double range = kLocationJitter;
    return ((double)arc4random_uniform(1000) / 1000.0 - 0.5) * 2.0 * range;
}

/// 当前瞬时速度 (带随机变化)
- (double)currentSpeed {
    double variation = ((double)arc4random_uniform(200) / 1000.0 - 0.15) * 2.0;
    return self.walkingSpeed * (1.0 + variation * kSpeedVariation);
}

/// 更新当前目标点
- (void)updateCurrentTarget {
    for (NSInteger i = 0; i < self.checkpointIndices.count; i++) {
        NSInteger cpPathIdx = [self.checkpointIndices[i] integerValue];
        if (cpPathIdx > self.pathIndex) {
            NSInteger cpIdx = [self.visitOrder[i] integerValue];
            self.currentTargetIndex = cpIdx;
            return;
        }
    }
    self.currentTargetIndex = -1; // 所有点都已走过
}

// ============================================================
#pragma mark - 核心: 开始/暂停/继续/停止
// ============================================================
- (void)startSimulationWithCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
                          visitOrder:(NSArray<NSNumber *> *)optimalOrder
                        startLocation:(CLLocation *)startLocation
                     routeCoordinates:(NSArray<NSValue *> *)routeCoordinates
                     onTick:(SWSimulatorTickBlock)tickBlock
                  onComplete:(SWSimulatorCompleteBlock)completeBlock {

    if (checkpoints.count < 2 || optimalOrder.count < 2) {
        NSLog(@"[SWRunHUD] ❌ 点位不足, 无法模拟");
        if (completeBlock) completeBlock(NO);
        return;
    }

    [self stopInternal];

    self.checkpoints = checkpoints;
    self.visitOrder  = optimalOrder;
    self.startLocation = [self locationLooksUsable:startLocation] ? startLocation : nil;
    self.routeCoordinates = routeCoordinates;
    self.tickBlock   = tickBlock;
    self.completeBlock = completeBlock;
    self.pathIndex = 0;
    self.traveledDistance = 0;
    self.elapsedSeconds = 0;
    self.simulationStartDate = [NSDate date];
    self.nextFloorDistance = 200.0;
    [self resetMotionData];

    // 生成路径点
    [self generatePathPoints];

    if (self.pathPoints.count < 2) {
        NSLog(@"[SWRunHUD] ❌ 路径点生成失败");
        self.state = SWSimulatorStateIdle;
        if (completeBlock) completeBlock(NO);
        return;
    }

    // 发送起始位置
    self.currentLocation = self.pathPoints[0];
    if (self.tickBlock) {
        self.tickBlock(self.currentLocation, 0);
    }

    // 启动定时器
    self.state = SWSimulatorStateRunning;
    [self startTickTimer];

    NSLog(@"[SWRunHUD] ▶️ 模拟开始: %lu 个路径点, %.0fm",
          (unsigned long)self.pathPoints.count, self.totalPathDistance);
}

- (void)pause {
    if (self.state != SWSimulatorStateRunning) return;
    self.state = SWSimulatorStatePaused;
    [self stopTickTimer];
    NSLog(@"[SWRunHUD] ⏸ 模拟暂停 (已走 %.0fm / %.0fm)", self.traveledDistance, self.totalPathDistance);
}

- (void)resume {
    if (self.state != SWSimulatorStatePaused) return;
    self.state = SWSimulatorStateRunning;
    [self startTickTimer];
    NSLog(@"[SWRunHUD] ▶️ 模拟继续");
}

- (void)stop {
    if (self.state == SWSimulatorStateIdle || self.state == SWSimulatorStateCompleted) return;
    [self stopInternal];
    NSLog(@"[SWRunHUD] ⏹ 模拟停止");
}

- (void)stopInternal {
    self.state = SWSimulatorStateIdle;
    [self stopTickTimer];
    self.tickBlock = nil;
    self.completeBlock = nil;
    self.pathIndex = 0;
    self.traveledDistance = 0;
    self.elapsedSeconds = 0;
    self.nextFloorDistance = 200.0;
    self.startLocation = nil;
    self.routeCoordinates = nil;
    [self resetMotionData];
}

// ============================================================
#pragma mark - 定时器
// ============================================================
- (void)startTickTimer {
    [self stopTickTimer];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:kTickInterval
                                                      target:self
                                                    selector:@selector(tickForward)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.tickTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTickTimer {
    if (self.tickTimer) {
        [self.tickTimer invalidate];
        self.tickTimer = nil;
    }
}

/// 每秒前进一步
- (void)tickForward {
    if (self.state != SWSimulatorStateRunning) return;

    // ★ 关键: 整次 tick 使用同一个速度值, 保证所有数据一致性
    double thisTickSpeed = [self currentSpeed];

    // 这一步移动的距离 = 速度 × 1秒
    double stepDistance = thisTickSpeed;

    double remainingDistance = self.totalPathDistance > 0 ? MAX(0, self.totalPathDistance - self.traveledDistance) : stepDistance;
    double actualStepDistance = MIN(stepDistance, remainingDistance);
    double actualSpeed = actualStepDistance / kTickInterval;

    self.traveledDistance += actualStepDistance;
    self.elapsedSeconds += 1.0;

    // ★ 更新运动传感器数据 (确保与GPS速度一致)
    [self updateMotionDataWithStepDistance:actualStepDistance speed:actualSpeed];

    // ★ 一致性校验 (每秒输出, 确保 speed↔cadence↔pace↔distance 全链路自洽)
    SWSimulatedMotionData *mdCheck = self.motionData;
    double checkDist   = mdCheck.numberOfSteps * mdCheck.stepLength;  // 步数×步长
    double checkSpeed  = mdCheck.currentCadence * mdCheck.stepLength; // 步频×步长
    double checkPace   = 1.0 / mdCheck.currentPace;                   // 1÷配速
    double drifts[3] = {
        fabs(checkDist - self.traveledDistance),
        fabs(checkSpeed - actualSpeed),
        fabs(checkPace - actualSpeed)
    };
    // 任一漂移 > 5% 时警告
    if (drifts[0] > self.traveledDistance * 0.05 ||
        drifts[1] > MAX(actualSpeed, 0.1) * 0.05 ||
        drifts[2] > MAX(actualSpeed, 0.1) * 0.05) {
        NSLog(@"[SWRunHUD] ⚠️⚠️⚠️ 数据不一致! dist偏差=%.1f speed偏差=%.2f pace偏差=%.2f",
              drifts[0], drifts[1], drifts[2]);
    }

    if (self.pathIndex < self.pathPoints.count) {
        // 更新位置: 按累计里程插值，避免 GPS 点位跳跃造成距离与计步器漂移
        double heading = self.motionData.currentHeading;
        CLLocation *updatedLoc = [self locationAtDistance:self.traveledDistance heading:&heading speed:actualSpeed];
        if (!updatedLoc) return;

        self.motionData.currentHeading  = heading;
        self.motionData.headingAccuracy = 5.0 + [self randomJitter] * 10;

        self.currentLocation = updatedLoc;

        // 更新目标
        [self updateCurrentTarget];

        // 回调
        if (self.tickBlock) {
            self.tickBlock(updatedLoc, (NSInteger)self.pathIndex);
        }
    }

    // 检查是否到达终点
    if (self.pathIndex >= self.pathPoints.count - 1) {
        [self stopTickTimer];
        self.state = SWSimulatorStateCompleted;
        self.currentTargetIndex = -1;
        NSLog(@"[SWRunHUD] ✅ 模拟完成! 总距离: %.0fm", self.traveledDistance);
        if (self.completeBlock) {
            self.completeBlock(YES);
        }
    }
}

// ============================================================
#pragma mark - 公开属性
// ============================================================
- (void)setWalkingSpeed:(double)speedMetersPerSecond {
    _walkingSpeed = MAX(0.5, MIN(speedMetersPerSecond, 5.0));
}

- (double)distanceToNextTarget {
    if (self.currentTargetIndex < 0 || self.currentTargetIndex >= self.checkpoints.count) return 0;
    SWRunCheckpoint *target = self.checkpoints[self.currentTargetIndex];
    CLLocation *targetLoc = [[CLLocation alloc] initWithLatitude:target.latitude
                                                       longitude:target.longitude];
    return [self.currentLocation distanceFromLocation:targetLoc];
}

// ============================================================
#pragma mark - ★ 运动传感器数据生成
// ============================================================

/// 每秒调用，根据行走距离更新步数/步频/爬楼/配速/高度/气压/航向
- (void)updateMotionDataWithStepDistance:(double)stepDistance speed:(double)speed {
    SWSimulatedMotionData *md = self.motionData;

    md.distance = self.traveledDistance;
    md.numberOfSteps = self.traveledDistance > 0 ? MAX(1, (NSInteger)llround(self.traveledDistance / kNominalStepLength)) : 0;
    md.stepLength = md.numberOfSteps > 0 ? self.traveledDistance / (double)md.numberOfSteps : kNominalStepLength;

    if (speed > 0.1) { md.currentPace = 1.0 / speed; }
    if (self.traveledDistance > 0) { md.averageActivePace = self.elapsedSeconds / self.traveledDistance; }
    md.currentCadence = md.stepLength > 0 ? speed / md.stepLength : 0;

    // 爬升
    if (self.traveledDistance >= self.nextFloorDistance) {
        uint32_t r = arc4random_uniform(100);
        if (r < 60) { md.floorsAscended += 1; }
        else if (r < 80) { md.floorsDescended += 1; }
        self.nextFloorDistance += 200.0;
    }

    // ★ 海拔高度变化: 每爬1层≈3m, 加上微小的地形起伏
    double floorAltitude = md.floorsAscended * 3.0 - md.floorsDescended * 2.5;
    double terrainNoise = ((double)arc4random_uniform(30) / 100.0 - 0.15); // ±0.15m
    md.currentAltitude = kBaseAltitude + floorAltitude + terrainNoise;
    md.relativeAltitude = md.currentAltitude - kBaseAltitude;

    // ★ 气压: CoreMotion pressure 使用 kPa, 每升高1m约下降0.012kPa
    md.currentPressure = 101.325 - md.relativeAltitude * 0.012;
}

- (void)resetMotionData {
    SWSimulatedMotionData *md = self.motionData;
    md.numberOfSteps = 0;
    md.distance = 0;
    md.currentPace = 0;
    md.averageActivePace = 0;
    md.currentCadence = 0;
    md.floorsAscended = 0;
    md.floorsDescended = 0;
    md.stepLength = kNominalStepLength;
    md.currentAltitude = kBaseAltitude;
    md.relativeAltitude = 0;
    md.currentPressure = 101.325;
    md.currentHeading = 0;
    md.headingAccuracy = 5.0;
}

/// ★ 计算两点之间的航向角 (度, 0=北, 90=东)
- (double)headingFrom:(CLLocationCoordinate2D)from to:(CLLocationCoordinate2D)to {
    double dLng = (to.longitude - from.longitude) * M_PI / 180.0;
    double fromLat = from.latitude * M_PI / 180.0;
    double toLat   = to.latitude   * M_PI / 180.0;
    double y = sin(dLng) * cos(toLat);
    double x = cos(fromLat) * sin(toLat) - sin(fromLat) * cos(toLat) * cos(dLng);
    double headingRad = atan2(y, x);
    double headingDeg = headingRad * 180.0 / M_PI;
    if (headingDeg < 0) headingDeg += 360.0;
    return headingDeg;
}

@end
