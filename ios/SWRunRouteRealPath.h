//
//  SWRunRouteRealPath.h
//  SWRunCheckpointHUD
//
//  真实步行路径计算器
//  1. 优先使用高德地图 SDK (已静态链接在 App 内)
//  2. 回退到 Apple MapKit MKDirections
//  3. 都不行则用 Haversine 直线距离并警告
//
//  核心功能: 计算两个 GPS 坐标之间的真实步行距离
//  避免"穿墙过河"的直线路径
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

/// 距离来源类型
typedef NS_ENUM(NSInteger, SWPathSource) {
    SWPathSourceAMap = 0,        // 高德地图步行路径
    SWPathSourceAppleMaps = 1,   // Apple 地图步行路径
    SWPathSourceStraightLine = 2 // 直线距离(无地图服务可用)
};

/// 单段路径结果
@interface SWPathSegment : NSObject

@property (nonatomic, assign) double        distance;       // 步行距离(米)
@property (nonatomic, assign) double        straightDistance; // 直线距离(米)
@property (nonatomic, assign) SWPathSource  source;         // 数据来源
@property (nonatomic, assign) double        duration;       // 预估时间(秒)
@property (nonatomic, assign) BOOL          isAvailable;    // 是否获取成功

@end

/// 距离矩阵构建器
/// 使用真实地图服务构建 N×N 步行距离矩阵
@interface SWRunRouteRealPath : NSObject

+ (instancetype)sharedInstance;

/// 计算两点之间的真实步行路径
/// @param from 起点
/// @param to 终点
/// @param completion 回调 (在主线程)
- (void)walkingDistanceFrom:(CLLocationCoordinate2D)from
                         to:(CLLocationCoordinate2D)to
                 completion:(void(^)(SWPathSegment *result))completion;

/// 批量计算: 构建 N 个点之间的完整距离矩阵
/// @param coordinates 坐标数组
/// @param completion 回调，返回 N×N 距离矩阵 (上三角已填充)
- (void)buildDistanceMatrix:(NSArray<NSValue *> *)coordinates
                 completion:(void(^)(double **matrix, NSInteger count, SWPathSource overallSource))completion;

/// 检查 AMap SDK 是否可用
- (BOOL)isAMapAvailable;

/// 检查 Apple Maps 是否可用
- (BOOL)isAppleMapsAvailable;

/// 获取当前最佳数据源描述
- (NSString *)dataSourceDescription;

@end

NS_ASSUME_NONNULL_END
