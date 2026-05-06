//
//  SWRunFloatingView.h
//  SWRunCheckpointHUD
//
//  运动世界校园跑 悬浮窗视图
//  显示必经点位(红色)和普通点位(蓝色)信息
//

#import <UIKit/UIKit.h>

@class SWRunRoutePlan;

NS_ASSUME_NONNULL_BEGIN

/// 单个打卡点数据模型
@interface SWRunCheckpoint : NSObject

@property (nonatomic, copy)   NSString *pointName;   // 点位名称
@property (nonatomic, assign) double    longitude;     // 经度
@property (nonatomic, assign) double    latitude;      // 纬度
@property (nonatomic, assign) BOOL      isFixed;       // YES=必经点/固定点, NO=普通点/随机点
@property (nonatomic, assign) BOOL      isPassed;      // 是否已通过
@property (nonatomic, assign) NSInteger position;      // 顺序位置

@end

/// 悬浮窗主视图
@interface SWRunFloatingView : UIView

/// 单例
+ (instancetype)sharedInstance;

/// 显示悬浮窗
- (void)show;

/// 隐藏悬浮窗
- (void)hide;

/// 更新点位数据
/// @param checkpoints 打卡点数组
/// @param totalDistance 总里程(米)
- (void)updateCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
            totalDistance:(double)totalDistance;

/// 更新路线规划
/// @param plan 路线规划结果
- (void)updateRoutePlan:(SWRunRoutePlan *)plan;

/// 设置模拟运行状态 (用于按钮切换)
/// @param running YES=正在模拟
- (void)setSimulationRunning:(BOOL)running;

/// 切换展开/收起
- (void)toggleExpand;

/// 更新实时位置标记
- (void)updateCurrentLocation:(double)lat lng:(double)lng;

@end

NS_ASSUME_NONNULL_END
