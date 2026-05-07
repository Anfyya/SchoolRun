//
//  SWRunSimulator.h
//  SWRunCheckpointHUD
//
//  步行路线模拟器
//  沿真实步行路径自动生成模拟 GPS 坐标序列
//  支持速度变化、暂停/继续、自然路径插值
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@class SWRunCheckpoint;

NS_ASSUME_NONNULL_BEGIN

/// 模拟位置回调: 每秒返回一个新的模拟坐标
typedef void(^SWSimulatorTickBlock)(CLLocation *simulatedLocation, NSInteger stepNumber);

/// 模拟完成回调
typedef void(^SWSimulatorCompleteBlock)(BOOL finished);

/// 模拟状态
typedef NS_ENUM(NSInteger, SWSimulatorState) {
    SWSimulatorStateIdle      = 0,  // 空闲
    SWSimulatorStateRunning   = 1,  // 正在模拟行走
    SWSimulatorStatePaused    = 2,  // 已暂停
    SWSimulatorStateCompleted = 3,  // 已完成
};

/// 模拟运动数据 (对应 CMPedometerData)
@interface SWSimulatedMotionData : NSObject

@property (nonatomic, assign) NSInteger numberOfSteps;       // 累计步数
@property (nonatomic, assign) double    distance;            // 累计距离(米)
@property (nonatomic, assign) double    currentPace;         // 当前配速(s/m)
@property (nonatomic, assign) double    averageActivePace;   // 平均配速(s/m)
@property (nonatomic, assign) double    currentCadence;      // 当前步频(steps/s)
@property (nonatomic, assign) NSInteger floorsAscended;      // 累计爬升楼层
@property (nonatomic, assign) NSInteger floorsDescended;     // 累计下降楼层
@property (nonatomic, assign) double    stepLength;          // 步长(米, 默认0.76=180cm男生)
@property (nonatomic, assign) double    currentAltitude;     // ★ 当前海拔(米)
@property (nonatomic, assign) double    relativeAltitude;    // ★ 相对起跑海拔(米)
@property (nonatomic, assign) double    currentPressure;     // ★ 气压(kPa, 随高度微变)
@property (nonatomic, assign) double    currentHeading;      // ★ 航向角(度, 0=北)
@property (nonatomic, assign) double    headingAccuracy;     // ★ 磁力计精度

@end

/// 步行路径模拟器
@interface SWRunSimulator : NSObject

+ (instancetype)sharedInstance;

/// 当前状态
@property (nonatomic, readonly) SWSimulatorState state;
/// 当前模拟坐标
@property (nonatomic, readonly) CLLocation *currentLocation;
/// 已走过的距离 (米)
@property (nonatomic, readonly) double traveledDistance;
/// 总路径距离 (米)
@property (nonatomic, readonly) double totalPathDistance;
/// 已用时间 (秒)
@property (nonatomic, readonly) double elapsedSeconds;
/// 模拟开始时间
@property (nonatomic, readonly) NSDate *simulationStartDate;
/// 当前目标点索引
@property (nonatomic, readonly) NSInteger currentTargetIndex;
/// ★ 当前模拟运动数据
@property (nonatomic, readonly) SWSimulatedMotionData *motionData;

/// 加载路线并开始模拟
/// @param checkpoints 打卡点数组
/// @param optimalOrder 最优访问顺序 (索引数组)
/// @param completion 完成回调
- (void)startSimulationWithCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
                          visitOrder:(NSArray<NSNumber *> *)optimalOrder
                        startLocation:(nullable CLLocation *)startLocation
                     onTick:(SWSimulatorTickBlock)tickBlock
                  onComplete:(nullable SWSimulatorCompleteBlock)completeBlock;

/// 暂停模拟
- (void)pause;

/// 继续模拟
- (void)resume;

/// 停止模拟
- (void)stop;

/// 设置步行速度 (米/秒, 默认 1.4)
- (void)setWalkingSpeed:(double)speedMetersPerSecond;

/// 获取到下一个目标点的估计距离
- (double)distanceToNextTarget;

@end

NS_ASSUME_NONNULL_END
