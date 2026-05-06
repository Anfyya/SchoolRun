//
//  SWRunRoutePlanner.h
//  SWRunCheckpointHUD
//
//  路线规划引擎 - 基于必经点位计算最优路径
//  使用 Haversine 公式 + TSP 暴力枚举 (5! = 120 种排列)
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@class SWRunCheckpoint;

NS_ASSUME_NONNULL_BEGIN

/// 路线规划结果
@interface SWRunRoutePlan : NSObject

/// 最优访问顺序
@property (nonatomic, copy)   NSArray<NSNumber *> *optimalOrder;
/// 原定访问顺序
@property (nonatomic, copy)   NSArray<NSNumber *> *originalOrder;
/// 最优路径总距离 (米)
@property (nonatomic, assign) double              optimalDistance;
/// 原定路径总距离 (米)
@property (nonatomic, assign) double              originalDistance;
/// 节省的距离 (米)
@property (nonatomic, assign) double              savedDistance;
/// 节省的时间 (秒)
@property (nonatomic, assign) double              savedTimeSeconds;
/// 估算总耗时 (分钟)
@property (nonatomic, assign) double              estimatedMinutes;
/// 点位间距明细
@property (nonatomic, copy)   NSArray<NSNumber *> *segmentDistances;
/// 下一个应前往的点位索引
@property (nonatomic, assign) NSInteger           nextTargetIndex;
/// 数据来源描述
@property (nonatomic, copy)   NSString           *dataSourceDesc;
/// 是否使用真实路径 (NO=直线估算, 可能穿墙过河)
@property (nonatomic, assign) BOOL                usesRealPath;

/// 格式化输出
- (NSString *)summaryString;

@end

/// 路线规划器
@interface SWRunRoutePlanner : NSObject

/// 单例
+ (instancetype)sharedInstance;

/// 根据打卡点列表计算最优路线 (使用真实步行路径)
/// @param checkpoints 所有打卡点
/// @param currentLat 当前纬度
/// @param currentLng 当前经度
/// @return 路线规划结果 (同步, 使用 Haversine 直线距离)
- (SWRunRoutePlan *)planOptimalRoute:(NSArray<SWRunCheckpoint *> *)checkpoints
                       fromLatitude:(double)currentLat
                      fromLongitude:(double)currentLng;

/// 异步版本: 使用真实步行路径 (高德/Apple Maps) 计算
/// @param checkpoints 所有打卡点
/// @param completion 回调 (主线程)
- (void)planOptimalRouteAsync:(NSArray<SWRunCheckpoint *> *)checkpoints
                    completion:(void(^)(SWRunRoutePlan *plan))completion;

/// 快速计算场景: 仅必经点最优路径
/// @param checkpoints 所有打卡点
/// @return 仅含必经点的规划结果 (必经点保持原顺序, 计算总距+耗时)
- (SWRunRoutePlan *)planFixedOnlyRoute:(NSArray<SWRunCheckpoint *> *)checkpoints;

/// 计算两点间 Haversine 距离 (米)
+ (double)distanceFromLat:(double)lat1 lng:(double)lng1
                    toLat:(double)lat2 lng:(double)lng2;

@end

NS_ASSUME_NONNULL_END
