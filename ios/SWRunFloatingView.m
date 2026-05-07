//
//  SWRunFloatingView.m
//  SWRunCheckpointHUD
//
//  悬浮窗实现 - Dopamine rootless 兼容
//

#import "SWRunFloatingView.h"
#import "SWRunRoutePlanner.h"
#import "SWRunRouteRealPath.h"
#import "SWRunSimulator.h"
#import <MapKit/MapKit.h>
#import <math.h>
#import <stdlib.h>

// ★ 引用 Tweak.x 中的模拟控制函数
extern void SWRunStartGPSSimulation(void);
extern void SWRunStopGPSSimulation(void);
extern void SWRunToggleSimulation(void);
extern void SWRunForceParseCheckpoints(void);

// ============================================================
#pragma mark - SWRunCheckpoint 实现
// ============================================================
@implementation SWRunCheckpoint

- (NSString *)description {
    NSString *typeLabel = self.isFixed ? @"🔴 必经点" : @"🔵 普通点";
    NSString *passedLabel = self.isPassed ? @" ✅已过" : @" ⬜未过";
    return [NSString stringWithFormat:@"%@%@ P%ld %@ (%.5f,%.5f)",
            typeLabel, passedLabel, (long)self.position,
            self.pointName, self.latitude, self.longitude];
}

@end

// ============================================================
#pragma mark - SWRunFloatingView 常量
// ============================================================
static CGFloat const kHeaderHeight     = 44.0;
static CGFloat const kRowHeight        = 42.0;
static CGFloat const kCollapsedWidth   = 56.0;
static CGFloat const kCollapsedHeight  = 56.0;
static CGFloat const kExpandedWidth    = 350.0;
static CGFloat const kMaxHeight        = 660.0;
static CGFloat const kMapHeight        = 320.0;
static CGFloat const kSimInfoHeight    = 118.0;
static CGFloat const kCornerRadius     = 12.0;
static double  const kMinimumRouteDistance = 1100.0;

@interface SWRunPassthroughWindow : UIWindow
@end

@implementation SWRunPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}

@end

// ============================================================
#pragma mark - SWRunFloatingView 实现
// ============================================================
@interface SWRunFloatingView () <UITableViewDataSource, UITableViewDelegate, MKMapViewDelegate>

@property (nonatomic, strong) UIWindow           *overlayWindow;
@property (nonatomic, strong) UIView             *containerView;
@property (nonatomic, strong) UILabel            *titleLabel;
@property (nonatomic, strong) UILabel            *distanceLabel;
@property (nonatomic, strong) UILabel            *routeInfoLabel;
@property (nonatomic, strong) UILabel            *simStatusLabel;     // 模拟状态
@property (nonatomic, strong) UIButton           *toggleBtn;
@property (nonatomic, strong) UIButton           *parseBtn;          // 主动解析点位
@property (nonatomic, strong) UIButton           *simBtn;            // ★ 模拟按钮
@property (nonatomic, strong) UIButton           *simStopBtn;        // ★ 停止按钮
@property (nonatomic, strong) MKMapView          *routeMapView;      // 路线小地图
@property (nonatomic, strong) UITableView        *tableView;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;

@property (nonatomic, strong) NSArray<SWRunCheckpoint *> *checkpoints;
@property (nonatomic, assign) double              totalDistance;
@property (nonatomic, assign) BOOL                isExpanded;
@property (nonatomic, assign) BOOL                isSimRunning;      // ★ 模拟状态
@property (nonatomic, assign) CGPoint             dragStartPoint;
@property (nonatomic, strong) SWRunRoutePlan     *currentPlan;       // 当前路线规划
@property (nonatomic, strong) MKPolyline         *routePolyline;
@property (nonatomic, strong) MKPointAnnotation  *currentLocationAnnotation;
@property (nonatomic, copy)   NSArray<NSValue *> *realRouteCoordinatesForMap;
@property (nonatomic, assign) CLLocationCoordinate2D currentDisplayCoordinate;
@property (nonatomic, assign) CLLocationCoordinate2D routeStartCoordinate;
@property (nonatomic, assign) BOOL                hasCurrentDisplayCoordinate;
@property (nonatomic, assign) BOOL                hasRouteStartCoordinate;
@property (nonatomic, assign) NSUInteger          routeMapRequestID;
@property (nonatomic, assign) BOOL                routeMapLoading;

@end

@implementation SWRunFloatingView

// ============================================================
#pragma mark - 单例
// ============================================================
+ (instancetype)sharedInstance {
    static SWRunFloatingView *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SWRunFloatingView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    });
    return instance;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        _isExpanded = NO;
        _checkpoints = @[];
        _totalDistance = 0;
        [self setupOverlayWindow];
        [self setupContainerView];
        [self setupHeader];
        [self setupMapView];
        [self setupTableView];
        [self setupGestures];
        [self collapseAnimated:NO];
    }
    return self;
}

// ============================================================
#pragma mark - UI 初始化
// ============================================================

- (void)setupOverlayWindow {
    // 使用独立的 UIWindow 确保悬浮在最上层
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
    }

    if (scene) {
        self.overlayWindow = [[SWRunPassthroughWindow alloc] initWithWindowScene:scene];
    } else {
        self.overlayWindow = [[SWRunPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }

    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController = [[UIViewController alloc] init];
    self.overlayWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow.rootViewController.view.userInteractionEnabled = YES;
    self.overlayWindow.userInteractionEnabled = YES;
    self.overlayWindow.hidden = YES;

    [self.overlayWindow.rootViewController.view addSubview:self];
}

- (void)setupContainerView {
    self.containerView = [[UIView alloc] init];
    self.containerView.backgroundColor = [[UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.92];
    self.containerView.layer.cornerRadius = kCornerRadius;
    self.containerView.layer.borderWidth = 1.5;
    self.containerView.layer.borderColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0].CGColor;
    self.containerView.clipsToBounds = YES;
    self.containerView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.containerView.layer.shadowOffset = CGSizeMake(0, 4);
    self.containerView.layer.shadowRadius = 8;
    self.containerView.layer.shadowOpacity = 0.5;
    [self addSubview:self.containerView];
}

- (void)setupHeader {
    // 标题栏
    UIView *headerView = [[UIView alloc] init];
    headerView.backgroundColor = [[UIColor colorWithRed:0.15 green:0.15 blue:0.22 alpha:1.0] colorWithAlphaComponent:1.0];
    [self.containerView addSubview:headerView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"🏃 跑步点位置";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:self.titleLabel];

    self.distanceLabel = [[UILabel alloc] init];
    self.distanceLabel.text = @"总里程: 0.00 km";
    self.distanceLabel.textColor = [UIColor colorWithRed:0.4 green:0.9 blue:0.6 alpha:1.0];
    self.distanceLabel.font = [UIFont systemFontOfSize:11];
    self.distanceLabel.textAlignment = NSTextAlignmentCenter;
    [headerView addSubview:self.distanceLabel];

    // 展开/收起按钮
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.toggleBtn setTitle:@"▼" forState:UIControlStateNormal];
    [self.toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [self.toggleBtn addTarget:self action:@selector(toggleExpand) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:self.toggleBtn];

    // 主动解析点位按钮
    self.parseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.parseBtn setTitle:@"解析" forState:UIControlStateNormal];
    [self.parseBtn setTitleColor:[UIColor colorWithRed:0.6 green:0.85 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    self.parseBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.parseBtn.backgroundColor = [[UIColor colorWithRed:0.2 green:0.55 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.18];
    self.parseBtn.layer.cornerRadius = 4;
    [self.parseBtn addTarget:self action:@selector(onParseButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:self.parseBtn];

    // ★ 模拟按钮
    self.simBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.simBtn setTitle:@"▶️模拟" forState:UIControlStateNormal];
    [self.simBtn setTitleColor:[UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0] forState:UIControlStateNormal];
    self.simBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    self.simBtn.backgroundColor = [[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0] colorWithAlphaComponent:0.15];
    self.simBtn.layer.cornerRadius = 4;
    [self.simBtn addTarget:self action:@selector(onSimButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:self.simBtn];

    // ★ 停止按钮 (初始隐藏)
    self.simStopBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.simStopBtn setTitle:@"⏹" forState:UIControlStateNormal];
    [self.simStopBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0] forState:UIControlStateNormal];
    self.simStopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.simStopBtn.hidden = YES;
    [self.simStopBtn addTarget:self action:@selector(onSimStopTapped) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:self.simStopBtn];

    // 模拟状态标签
    self.simStatusLabel = [[UILabel alloc] init];
    self.simStatusLabel.text = @"";
    self.simStatusLabel.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0];
    self.simStatusLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
    self.simStatusLabel.textAlignment = NSTextAlignmentLeft;
    self.simStatusLabel.numberOfLines = 0;
    [self.containerView addSubview:self.simStatusLabel];

    // 路线规划摘要标签
    self.routeInfoLabel = [[UILabel alloc] init];
    self.routeInfoLabel.text = @"";
    self.routeInfoLabel.textColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1.0];
    self.routeInfoLabel.font = [UIFont systemFontOfSize:10];
    self.routeInfoLabel.textAlignment = NSTextAlignmentCenter;
    self.routeInfoLabel.numberOfLines = 0;
    [self.containerView addSubview:self.routeInfoLabel];
}

- (void)setupRouteInfoLabel {
    // 已合并到 setupHeader
}

- (void)setupMapView {
    self.routeMapView = [[MKMapView alloc] initWithFrame:CGRectZero];
    self.routeMapView.delegate = self;
    self.routeMapView.mapType = MKMapTypeStandard;
    self.routeMapView.scrollEnabled = NO;
    self.routeMapView.zoomEnabled = NO;
    self.routeMapView.rotateEnabled = NO;
    self.routeMapView.pitchEnabled = NO;
    self.routeMapView.showsCompass = NO;
    self.routeMapView.showsScale = NO;
    self.routeMapView.showsUserLocation = NO;
    self.routeMapView.userInteractionEnabled = NO;
    self.routeMapView.layer.cornerRadius = 8.0;
    self.routeMapView.clipsToBounds = YES;
    self.routeMapView.hidden = YES;
    [self.containerView addSubview:self.routeMapView];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.3 alpha:0.5];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = kRowHeight;
    self.tableView.estimatedRowHeight = kRowHeight;
    self.tableView.showsVerticalScrollIndicator = YES;
    self.tableView.allowsSelection = NO;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"CheckpointCell"];
    [self.containerView addSubview:self.tableView];
}

- (void)setupGestures {
    self.panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.containerView addGestureRecognizer:self.panGesture];
}

// ============================================================
#pragma mark - 路线小地图
// ============================================================
- (double)distanceForCoordinates:(NSArray<NSValue *> *)coords {
    if (coords.count < 2) return 0;

    double total = 0;
    CLLocationCoordinate2D prev;
    [coords[0] getValue:&prev];
    CLLocation *prevLoc = [[CLLocation alloc] initWithLatitude:prev.latitude longitude:prev.longitude];

    for (NSInteger i = 1; i < coords.count; i++) {
        CLLocationCoordinate2D coord;
        [coords[i] getValue:&coord];
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:coord.latitude longitude:coord.longitude];
        total += [prevLoc distanceFromLocation:loc];
        prevLoc = loc;
    }
    return total;
}

- (NSArray<NSNumber *> *)effectiveRouteOrder {
    NSArray<NSNumber *> *order = self.currentPlan.optimalOrder.count > 0
        ? self.currentPlan.optimalOrder
        : nil;
    if (!order) {
        NSMutableArray<NSNumber *> *fallbackOrder = [NSMutableArray arrayWithCapacity:self.checkpoints.count];
        for (NSInteger i = 0; i < self.checkpoints.count; i++) {
            [fallbackOrder addObject:@(i)];
        }
        order = fallbackOrder;
    }
    return order;
}

- (NSArray<NSValue *> *)routeControlCoordinates {
    if (self.checkpoints.count < 2) return @[];

    NSArray<NSNumber *> *order = [self effectiveRouteOrder];
    NSMutableArray<NSValue *> *coords = [NSMutableArray array];
    if (self.hasRouteStartCoordinate) {
        [coords addObject:[NSValue valueWithMKCoordinate:self.routeStartCoordinate]];
    }

    for (NSNumber *idxNum in order) {
        NSInteger idx = [idxNum integerValue];
        if (idx < 0 || idx >= self.checkpoints.count) continue;
        SWRunCheckpoint *cp = self.checkpoints[idx];
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(cp.latitude, cp.longitude);
        if (fabs(coord.latitude) < 0.000001 || fabs(coord.longitude) < 0.000001) continue;
        [coords addObject:[NSValue valueWithMKCoordinate:coord]];
    }
    return coords;
}

- (NSArray<NSValue *> *)coordinatesByRetracingToMinimumDistance:(NSArray<NSValue *> *)sourceCoords {
    if (sourceCoords.count < 2) return sourceCoords ?: @[];

    NSMutableArray<NSValue *> *coords = [sourceCoords mutableCopy];
    NSArray<NSValue *> *baseCoords = [sourceCoords copy];
    double routeDistance = [self distanceForCoordinates:coords];
    NSInteger guard = 0;

    while (routeDistance < kMinimumRouteDistance && guard < 8) {
        guard++;
        for (NSInteger i = (NSInteger)baseCoords.count - 2; i >= 0 && routeDistance < kMinimumRouteDistance; i--) {
            CLLocationCoordinate2D last;
            [[coords lastObject] getValue:&last];
            CLLocationCoordinate2D next;
            [baseCoords[i] getValue:&next];
            routeDistance += [SWRunRoutePlanner distanceFromLat:last.latitude lng:last.longitude
                                                          toLat:next.latitude lng:next.longitude];
            [coords addObject:baseCoords[i]];
        }
        for (NSInteger i = 1; i < baseCoords.count && routeDistance < kMinimumRouteDistance; i++) {
            CLLocationCoordinate2D last;
            [[coords lastObject] getValue:&last];
            CLLocationCoordinate2D next;
            [baseCoords[i] getValue:&next];
            routeDistance += [SWRunRoutePlanner distanceFromLat:last.latitude lng:last.longitude
                                                          toLat:next.latitude lng:next.longitude];
            [coords addObject:baseCoords[i]];
        }
    }

    return coords;
}

- (NSArray<NSValue *> *)routeCoordinatesForMap {
    if (self.routeMapLoading && self.realRouteCoordinatesForMap.count < 2) return @[];

    NSArray<NSValue *> *coords = self.realRouteCoordinatesForMap.count >= 2
        ? self.realRouteCoordinatesForMap
        : [self routeControlCoordinates];
    return [self coordinatesByRetracingToMinimumDistance:coords];
}

- (void)rebuildRealRouteMapPath {
    NSArray<NSValue *> *controls = [self routeControlCoordinates];
    if (controls.count < 2) {
        self.realRouteCoordinatesForMap = nil;
        self.routeMapLoading = NO;
        [self refreshRouteMap];
        return;
    }

    NSUInteger requestID = ++self.routeMapRequestID;
    self.realRouteCoordinatesForMap = nil;
    self.routeMapLoading = YES;
    [self refreshRouteMap];

    [[SWRunRouteRealPath sharedInstance] walkingRouteCoordinatesForCoordinates:controls
                                                                    completion:^(NSArray<NSValue *> *routeCoordinates, SWPathSource source) {
        (void)source;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (requestID != self.routeMapRequestID) return;
            self.routeMapLoading = NO;
            self.realRouteCoordinatesForMap = routeCoordinates.count >= 2 ? routeCoordinates : controls;
            [self refreshRouteMap];
        });
    }];
}

- (void)addCurrentLocationAnnotationIfNeeded {
    if (!self.hasCurrentDisplayCoordinate) return;

    self.currentLocationAnnotation = [[MKPointAnnotation alloc] init];
    self.currentLocationAnnotation.coordinate = self.currentDisplayCoordinate;
    self.currentLocationAnnotation.title = @"当前位置";
    [self.routeMapView addAnnotation:self.currentLocationAnnotation];
}

- (void)refreshRouteMap {
    if (!self.routeMapView) return;

    [self.routeMapView removeOverlays:self.routeMapView.overlays];
    [self.routeMapView removeAnnotations:self.routeMapView.annotations];

    NSArray<NSValue *> *coords = [self routeCoordinatesForMap];
    if (coords.count < 2) {
        self.routeMapView.hidden = YES;
        return;
    }

    CLLocationCoordinate2D *polyCoords = (CLLocationCoordinate2D *)calloc(coords.count, sizeof(CLLocationCoordinate2D));
    if (!polyCoords) {
        self.routeMapView.hidden = YES;
        return;
    }
    for (NSInteger i = 0; i < coords.count; i++) {
        [coords[i] getValue:&polyCoords[i]];
    }

    self.routePolyline = [MKPolyline polylineWithCoordinates:polyCoords count:coords.count];
    free(polyCoords);
    [self.routeMapView addOverlay:self.routePolyline];

    for (NSInteger i = 0; i < self.checkpoints.count; i++) {
        SWRunCheckpoint *cp = self.checkpoints[i];
        if (fabs(cp.latitude) < 0.000001 || fabs(cp.longitude) < 0.000001) continue;
        MKPointAnnotation *annotation = [[MKPointAnnotation alloc] init];
        annotation.coordinate = CLLocationCoordinate2DMake(cp.latitude, cp.longitude);
        annotation.title = cp.pointName.length > 0 ? cp.pointName : [NSString stringWithFormat:@"P%ld", (long)(i + 1)];
        [self.routeMapView addAnnotation:annotation];
    }
    [self addCurrentLocationAnnotationIfNeeded];

    MKMapRect mapRect = self.routePolyline.boundingMapRect;
    if (self.hasCurrentDisplayCoordinate) {
        MKMapPoint currentPoint = MKMapPointForCoordinate(self.currentDisplayCoordinate);
        mapRect = MKMapRectUnion(mapRect, MKMapRectMake(currentPoint.x, currentPoint.y, 1, 1));
    }
    if (!MKMapRectIsNull(mapRect) && !MKMapRectIsEmpty(mapRect)) {
        [self.routeMapView setVisibleMapRect:mapRect
                                 edgePadding:UIEdgeInsetsMake(10, 10, 10, 10)
                                    animated:NO];
    }
    self.routeMapView.hidden = NO;
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if ([overlay isKindOfClass:[MKPolyline class]]) {
        MKPolylineRenderer *renderer = [[MKPolylineRenderer alloc] initWithPolyline:(MKPolyline *)overlay];
        renderer.strokeColor = [UIColor colorWithRed:0.1 green:0.55 blue:1.0 alpha:0.95];
        renderer.lineWidth = 4.0;
        renderer.lineJoin = kCGLineJoinRound;
        renderer.lineCap = kCGLineCapRound;
        return renderer;
    }
    return [[MKOverlayRenderer alloc] initWithOverlay:overlay];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if (annotation == self.currentLocationAnnotation) {
        static NSString *currentIdentifier = @"SWRunCurrentAnnotation";
        MKMarkerAnnotationView *currentView = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:currentIdentifier];
        if (!currentView) {
            currentView = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:currentIdentifier];
            currentView.canShowCallout = NO;
        } else {
            currentView.annotation = annotation;
        }
        currentView.markerTintColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.35 alpha:1.0];
        currentView.glyphTintColor = [UIColor whiteColor];
        currentView.glyphText = @"●";
        return currentView;
    }

    static NSString *identifier = @"SWRunPointAnnotation";
    MKMarkerAnnotationView *view = (MKMarkerAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:identifier];
    if (!view) {
        view = [[MKMarkerAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:identifier];
        view.canShowCallout = NO;
    } else {
        view.annotation = annotation;
    }
    view.markerTintColor = [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:1.0];
    view.glyphTintColor = [UIColor whiteColor];
    view.glyphText = @"";
    return view;
}

// ============================================================
#pragma mark - 布局
// ============================================================
- (void)layoutSubviews {
    [super layoutSubviews];

    if (self.isExpanded) {
        self.frame = self.superview.bounds;

        CGFloat yPos = 80;
        CGFloat maxPanelHeight = MIN(kMaxHeight, self.superview.bounds.size.height - yPos - 20);
        CGFloat panelWidth = MIN(kExpandedWidth, self.superview.bounds.size.width - 20);

        // 路线摘要高度
        CGFloat routeInfoH = 0;
        if (self.currentPlan && self.currentPlan.optimalOrder.count > 0) {
            routeInfoH = 52; // 约3行文本高度
        }

        CGFloat simStatusH = self.simStatusLabel.text.length > 0 ? kSimInfoHeight : 0;
        CGFloat mapH = 0;
        if (self.checkpoints.count >= 2) {
            CGFloat availableMapHeight = maxPanelHeight - kHeaderHeight - routeInfoH - simStatusH;
            mapH = MIN(kMapHeight, MAX(180.0, availableMapHeight));
            if (availableMapHeight < 180.0) {
                mapH = MAX(0, availableMapHeight);
            }
        }
        CGFloat tableHeight = 0;
        CGFloat totalHeight = kHeaderHeight + routeInfoH + mapH + simStatusH + tableHeight;

        self.containerView.frame = CGRectMake(10, yPos, panelWidth, MIN(totalHeight, maxPanelHeight));
        self.containerView.layer.cornerRadius = kCornerRadius;

        // Header
        UIView *header = self.containerView.subviews.firstObject;
        header.frame = CGRectMake(0, 0, panelWidth, kHeaderHeight);

        self.toggleBtn.frame = CGRectMake(4, 4, 36, 36);

        // ★ 模拟按钮布局
        self.parseBtn.frame = CGRectMake(panelWidth - 162, 6, 42, 26);
        self.simBtn.frame = CGRectMake(panelWidth - 75, 6, 65, 26);
        self.simStopBtn.frame = CGRectMake(panelWidth - 116, 6, 36, 26);

        self.titleLabel.frame = CGRectMake(40, 0, panelWidth - 205, 26);
        self.distanceLabel.frame = CGRectMake(40, 22, panelWidth - 205, 20);

        // Route Info (在 header 下方)
        if (routeInfoH > 0) {
            self.routeInfoLabel.frame = CGRectMake(8, kHeaderHeight, panelWidth - 16, routeInfoH);
            self.routeInfoLabel.hidden = NO;
        } else {
            self.routeInfoLabel.frame = CGRectZero;
            self.routeInfoLabel.hidden = YES;
        }

        CGFloat mapY = kHeaderHeight + routeInfoH;
        if (mapH > 10) {
            self.routeMapView.frame = CGRectMake(8, mapY + 6, panelWidth - 16, mapH - 10);
            self.routeMapView.hidden = NO;
        } else {
            self.routeMapView.frame = CGRectZero;
            self.routeMapView.hidden = YES;
        }

        // Sim Status
        if (simStatusH > 0) {
            self.simStatusLabel.frame = CGRectMake(10, kHeaderHeight + routeInfoH + mapH, panelWidth - 20, simStatusH);
            self.simStatusLabel.hidden = NO;
        } else {
            self.simStatusLabel.frame = CGRectZero;
            self.simStatusLabel.hidden = YES;
        }

        // Table
        CGFloat tableY = kHeaderHeight + routeInfoH + mapH + simStatusH;
        self.tableView.frame = CGRectMake(0, tableY, panelWidth, tableHeight);
        self.tableView.hidden = YES;
    } else {
        // 收起状态：悬浮小圆点
        CGFloat screenWidth = self.superview.bounds.size.width;
        CGFloat screenHeight = self.superview.bounds.size.height;
        // ★ 让 frame 足够大以包含 containerView, 确保命中测试有效
        CGFloat margin = 16;
        self.frame = CGRectMake(screenWidth - kCollapsedWidth - margin,
                                screenHeight * 0.35 - margin,
                                kCollapsedWidth + margin * 2,
                                kCollapsedHeight + margin * 2);

        self.containerView.frame = CGRectMake(margin, margin,
                                               kCollapsedWidth, kCollapsedHeight);
        self.containerView.layer.cornerRadius = kCollapsedWidth / 2.0;

        UIView *header = self.containerView.subviews.firstObject;
        header.frame = self.containerView.bounds;
        self.parseBtn.hidden = YES;
        self.simBtn.hidden = YES;
        self.simStopBtn.hidden = YES;
        self.simStatusLabel.hidden = YES;
        self.routeInfoLabel.hidden = YES;
        self.routeMapView.hidden = YES;
        self.toggleBtn.frame = self.containerView.bounds;
        self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        self.titleLabel.frame = CGRectZero;
        self.distanceLabel.frame = CGRectZero;
        self.tableView.frame = CGRectZero;
        self.tableView.hidden = YES;
    }
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint containerPoint = [self convertPoint:point toView:self.containerView];
    return [self.containerView pointInside:containerPoint withEvent:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    return hitView == self ? nil : hitView;
}

// ============================================================
#pragma mark - 展开/收起
// ============================================================
- (void)expandAnimated:(BOOL)animated {
    self.isExpanded = YES;
    self.tableView.hidden = YES;
    self.parseBtn.hidden = NO;
    self.simBtn.hidden = NO;
    self.simStopBtn.hidden = !self.isSimRunning;
    [self.toggleBtn setTitle:@"▲" forState:UIControlStateNormal];
    self.containerView.layer.cornerRadius = kCornerRadius;

    [UIView animateWithDuration:animated ? 0.3 : 0 animations:^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
}

- (void)collapseAnimated:(BOOL)animated {
    self.isExpanded = NO;
    self.tableView.hidden = YES;
    [self.toggleBtn setTitle:@"📍" forState:UIControlStateNormal];
    [self.toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleBtn.titleLabel.font = [UIFont systemFontOfSize:24];
    self.containerView.layer.cornerRadius = kCollapsedWidth / 2.0;

    [UIView animateWithDuration:animated ? 0.3 : 0 animations:^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
}

- (void)toggleExpand {
    if (self.isExpanded) {
        [self collapseAnimated:YES];
    } else {
        [self expandAnimated:YES];
    }
}

// ============================================================
#pragma mark - 显示/隐藏
// ============================================================
- (void)show {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = NO;
        [self expandAnimated:YES];
        // 5秒后自动收起
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
        [self performSelector:@selector(autoCollapse) withObject:nil afterDelay:5.0];
    });
}

- (void)showCollapsed {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.overlayWindow.hidden = NO;
        self.containerView.alpha = 1.0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(autoCollapse) object:nil];
        [self collapseAnimated:NO];
    });
}

- (void)hide {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{
            self.containerView.alpha = 0;
        } completion:^(BOOL finished) {
            self.overlayWindow.hidden = YES;
            self.containerView.alpha = 1.0;
            [self collapseAnimated:NO];
        }];
    });
}

- (void)autoCollapse {
    if (self.isExpanded) {
        [self collapseAnimated:YES];
    }
}

// ============================================================
#pragma mark - 数据更新
// ============================================================
- (void)updateCheckpoints:(NSArray<SWRunCheckpoint *> *)checkpoints
            totalDistance:(double)totalDistance {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.checkpoints = checkpoints ?: @[];
        self.totalDistance = totalDistance;
        self.realRouteCoordinatesForMap = nil;
        self.routeMapLoading = NO;
        self.routeMapRequestID++;

        double km = totalDistance / 1000.0;
        self.distanceLabel.text = [NSString stringWithFormat:@"总里程: %.2f km", km];

        NSInteger fixedCount = 0;
        NSInteger passedFixed = 0;
        for (SWRunCheckpoint *cp in checkpoints) {
            if (cp.isFixed) {
                fixedCount++;
                if (cp.isPassed) passedFixed++;
            }
        }
        self.titleLabel.text = [NSString stringWithFormat:@"🏃 点位 (%ld/%ld 必经)",
                                (long)passedFixed, (long)fixedCount];

        [self.tableView reloadData];
        [self rebuildRealRouteMapPath];
        [self setNeedsLayout];

        // 有数据时自动弹出
        if (checkpoints.count > 0 && !self.isExpanded) {
            [self show];
        }
    });
}

- (void)updateCurrentLocation:(double)lat lng:(double)lng {
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat, lng);
        if (!CLLocationCoordinate2DIsValid(coord) ||
            fabs(coord.latitude) < 0.000001 ||
            fabs(coord.longitude) < 0.000001) {
            return;
        }

        BOOL routeNeedsRefresh = NO;
        if (!self.isSimRunning) {
            routeNeedsRefresh = !self.hasRouteStartCoordinate ||
                fabs(self.routeStartCoordinate.latitude - coord.latitude) > 0.000001 ||
                fabs(self.routeStartCoordinate.longitude - coord.longitude) > 0.000001;
            self.routeStartCoordinate = coord;
            self.hasRouteStartCoordinate = YES;
        } else if (!self.hasRouteStartCoordinate) {
            routeNeedsRefresh = YES;
            self.routeStartCoordinate = coord;
            self.hasRouteStartCoordinate = YES;
        }

        self.currentDisplayCoordinate = coord;
        self.hasCurrentDisplayCoordinate = YES;
        if (self.currentLocationAnnotation) {
            self.currentLocationAnnotation.coordinate = coord;
        }

        if (routeNeedsRefresh) {
            [self rebuildRealRouteMapPath];
        } else if (self.currentLocationAnnotation) {
            MKMapPoint point = MKMapPointForCoordinate(coord);
            MKMapRect visible = self.routeMapView.visibleMapRect;
            if (!MKMapRectContainsPoint(visible, point)) {
                [self refreshRouteMap];
            }
        } else {
            [self refreshRouteMap];
        }
    });
}

- (void)updateSimulationStatus:(NSString *)status location:(CLLocation *)location {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (location) {
            [self updateCurrentLocation:location.coordinate.latitude lng:location.coordinate.longitude];
        }
        self.simStatusLabel.text = status ?: @"";
        self.simStatusLabel.hidden = self.simStatusLabel.text.length == 0;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    });
}

- (void)updateRoutePlan:(SWRunRoutePlan *)plan {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentPlan = plan;
        if (!plan) {
            self.routeInfoLabel.text = @"";
            self.routeInfoLabel.hidden = YES;
            self.realRouteCoordinatesForMap = nil;
            self.routeMapLoading = NO;
            self.routeMapRequestID++;
            [self setNeedsLayout];
            return;
        }

        // 构建路线摘要文本
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];

        // 数据源标签 (绿色=真实路径 / 红色=直线警告)
        if (plan.dataSourceDesc.length > 0) {
            UIColor *sourceColor = plan.usesRealPath ?
                [UIColor colorWithRed:0.3 green:0.9 blue:0.4 alpha:1.0] :
                [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0];
            NSAttributedString *sourceA = [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"%@\n", plan.dataSourceDesc] attributes:@{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                NSForegroundColorAttributeName: sourceColor
            }];
            [attr appendAttributedString:sourceA];
        }

        // 标题行
        NSAttributedString *titleA = [[NSAttributedString alloc] initWithString:@"📐 路线规划\n" attributes:@{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1.0]
        }];
        [attr appendAttributedString:titleA];

        // 最优路径
        NSMutableString *orderStr = [NSMutableString string];
        for (NSInteger i = 0; i < plan.optimalOrder.count; i++) {
            [orderStr appendFormat:@"%ld", (long)[plan.optimalOrder[i] integerValue] + 1];
            if (i < plan.optimalOrder.count - 1) [orderStr appendString:@"→"];
        }

        NSAttributedString *pathA = [[NSAttributedString alloc] initWithString:
            [NSString stringWithFormat:@"路径: %@  %.0fm\n", orderStr, plan.optimalDistance] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.7 green:1.0 blue:0.7 alpha:1.0]
        }];
        [attr appendAttributedString:pathA];

        // 节省信息
        if (plan.savedDistance > 1.0) {
            NSAttributedString *saveA = [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"⚡ 节省 %.0fm / %.0fs | 预计 %.1fmin",
                 plan.savedDistance, plan.savedTimeSeconds, plan.estimatedMinutes] attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:10],
                NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.6 blue:0.3 alpha:1.0]
            }];
            [attr appendAttributedString:saveA];
        } else {
            NSAttributedString *saveA = [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"🕐 预计耗时 %.1f 分钟", plan.estimatedMinutes] attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:10],
                NSForegroundColorAttributeName: [UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1.0]
            }];
            [attr appendAttributedString:saveA];
        }

        // 下一个目标
        if (plan.nextTargetIndex >= 0) {
            NSAttributedString *nextA = [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"\n🎯 下个点: 第%ld个", (long)(plan.nextTargetIndex + 1)] attributes:@{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0]
            }];
            [attr appendAttributedString:nextA];
        }

        self.routeInfoLabel.attributedText = attr;
        self.routeInfoLabel.hidden = NO;
        [self rebuildRealRouteMapPath];

        // 刷新布局
        [self setNeedsLayout];
        [self layoutIfNeeded];
    });
}

// ============================================================
#pragma mark - 拖拽手势
// ============================================================
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStartPoint = self.containerView.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint newCenter = CGPointMake(self.dragStartPoint.x + translation.x,
                                         self.dragStartPoint.y + translation.y);
        // 边界限制
        CGFloat halfW = self.containerView.bounds.size.width / 2.0;
        CGFloat halfH = self.containerView.bounds.size.height / 2.0;
        CGFloat maxX = self.superview.bounds.size.width - halfW;
        CGFloat maxY = self.superview.bounds.size.height - halfH;
        newCenter.x = MAX(halfW, MIN(newCenter.x, maxX));
        newCenter.y = MAX(halfH + 40, MIN(newCenter.y, maxY));
        self.containerView.center = newCenter;
    }
}

// ============================================================
#pragma mark - UITableViewDataSource
// ============================================================
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.checkpoints.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"CheckpointCell"
                                                            forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];

    SWRunCheckpoint *cp = self.checkpoints[indexPath.row];

    // 必经点红色背景，普通点蓝色背景
    if (cp.isFixed) {
        cell.contentView.backgroundColor = [[UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1.0] colorWithAlphaComponent:0.25];
    } else {
        cell.contentView.backgroundColor = [[UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1.0] colorWithAlphaComponent:0.20];
    }

    // 已通过的点位加亮
    if (cp.isPassed) {
        cell.contentView.backgroundColor = [cell.contentView.backgroundColor colorWithAlphaComponent:0.6];
    }

    // 构建显示文本
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];

    // 类型标签
    NSString *typeStr = cp.isFixed ? @"🔴[必经] " : @"🔵[普通] ";
    NSAttributedString *typeAttr = [[NSAttributedString alloc] initWithString:typeStr attributes:@{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: cp.isFixed ?
            [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0] :
            [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]
    }];
    [attr appendAttributedString:typeAttr];

    // 点位名称
    NSAttributedString *nameAttr = [[NSAttributedString alloc] initWithString:cp.pointName attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    }];
    [attr appendAttributedString:nameAttr];

    // 通过状态
    NSString *statusStr = cp.isPassed ? @"  ✅" : @"  ⬜";
    NSAttributedString *statusAttr = [[NSAttributedString alloc] initWithString:statusStr attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: cp.isPassed ?
            [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0] :
            [UIColor colorWithRed:0.6 green:0.6 blue:0.6 alpha:1.0]
    }];
    [attr appendAttributedString:statusAttr];

    cell.textLabel.attributedText = attr;
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;

    return cell;
}

// ============================================================
#pragma mark - UITableViewDelegate
// ============================================================
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

// ============================================================
#pragma mark - ★ 模拟控制
// ============================================================
- (void)onSimButtonTapped {
    if (self.isSimRunning) {
        // 暂停
        SWRunToggleSimulation();
    } else {
        // 开始
        SWRunStartGPSSimulation();
    }
}

- (void)onParseButtonTapped {
    [self.parseBtn setTitle:@"..." forState:UIControlStateNormal];
    self.titleLabel.text = @"🔎 解析点位中";
    SWRunForceParseCheckpoints();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        [self.parseBtn setTitle:@"解析" forState:UIControlStateNormal];
        if (self.checkpoints.count == 0) {
            self.titleLabel.text = @"未找到点位";
        }
    });
}

- (void)onSimStopTapped {
    SWRunStopGPSSimulation();
}

- (void)setSimulationRunning:(BOOL)running {
    self.isSimRunning = running;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (running) {
            [self.simBtn setTitle:@"⏸暂停" forState:UIControlStateNormal];
            [self.simBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0] forState:UIControlStateNormal];
            self.simStopBtn.hidden = NO;

            // ★ 完整运动数据状态
            SWRunSimulator *sim = [SWRunSimulator sharedInstance];
            SWSimulatedMotionData *md = sim.motionData;
            CLLocation *loc = sim.currentLocation;
            NSString *targetText = sim.currentTargetIndex >= 0
                ? [NSString stringWithFormat:@"P%ld", (long)(sim.currentTargetIndex + 1)]
                : @"补足距离";
            self.simStatusLabel.text = [NSString stringWithFormat:
                @"模拟中 %.0f/%.0fm  %.0fs\n步数 %ld  步频 %.0f步/分  配速 %.2fs/m\n海拔 %.1fm  气压 %.2fkPa  航向 %.0f°\n当前位置 %.6f, %.6f  目标 %@",
                sim.traveledDistance, sim.totalPathDistance,
                sim.elapsedSeconds,
                (long)md.numberOfSteps,
                md.currentCadence * 60.0,
                md.currentPace,
                md.currentAltitude,
                md.currentPressure,
                md.currentHeading,
                loc.coordinate.latitude,
                loc.coordinate.longitude,
                targetText];
        } else {
            [self.simBtn setTitle:@"▶️模拟" forState:UIControlStateNormal];
            [self.simBtn setTitleColor:[UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1.0] forState:UIControlStateNormal];
            self.simStopBtn.hidden = YES;
            self.simStatusLabel.text = @"";
            self.simStatusLabel.hidden = YES;
        }
        [self setNeedsLayout];
    });
}

@end
