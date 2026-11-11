#import "ToastItem.h"
#include <math.h>

// 卡片外的透明留白，给 3D 倾斜留位置
@interface ToastContainerView : NSView
@end

@implementation ToastContainerView
// 落在留白上的点击要穿透，否则上面一条会挡住下面一条
- (NSView *)hitTest:(NSPoint)point {
	NSView *hit = [super hitTest:point];
	return hit == self ? nil : hit;
}
@end

@interface ToastItem ()
@property (nonatomic) int generation;
@property (nonatomic, copy) dispatch_block_t dismissBlock;
@property (nonatomic) NSTimer *animTimer;
@property (nonatomic) NSInteger animStep, animSteps;
@property (nonatomic) CGFloat animStartAlpha, animTargetAlpha;
@property (nonatomic) NSRect animStartFrame, animTargetFrame;
@property (nonatomic) BOOL animMove;
@property (nonatomic, copy) dispatch_block_t animCompletion;
@end

@implementation ToastItem

- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config {
	self = [super init];
	if (!self) return nil;

	_card = [[ToastCardView alloc] initWithPayload:payload config:config];

	// 留白只在开悬停时留：倾斜会撑出卡片边界，不给留白四角会直接被裁切
	CGFloat gutter = config.hoverEnabled ? MAX(config.hoverMargin, 0) : 0;
	CGFloat panelWidth = config.width + gutter * 2;
	CGFloat panelHeight = _card.cardHeight + gutter * 2;

	NSWindowStyleMask style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
	// 无边框 + 不激活：弹出时不抢焦点，玻璃材质也要求背景透明
	_panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, panelWidth, panelHeight)
	                                   styleMask:style
	                                     backing:NSBackingStoreBuffered
	                                       defer:NO];
	ToastContainerView *container = [[ToastContainerView alloc] initWithFrame:NSMakeRect(0, 0, panelWidth, panelHeight)];
	_card.frame = NSMakeRect(gutter, gutter, config.width, _card.cardHeight);
	[container addSubview:_card];
	_panel.contentView = container;
	_panel.acceptsMouseMovedEvents = YES;
	_panel.opaque = NO;
	_panel.backgroundColor = NSColor.clearColor;
	_panel.hasShadow = config.shadow;
	_panel.floatingPanel = YES;
	_panel.becomesKeyOnlyIfNeeded = YES;
	_panel.hidesOnDeactivate = NO;
	_panel.movableByWindowBackground = NO;
	_panel.releasedWhenClosed = NO;
	_panel.animationBehavior = NSWindowAnimationBehaviorNone;

	// 主题写了 dark/light 就固定面板外观，写 system 时让面板跟系统走
	NSString *theme = [config.theme lowercaseString];
	if ([theme isEqualToString:@"dark"]) {
		_panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
	} else if ([theme isEqualToString:@"light"]) {
		_panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantLight];
	} else {
		_panel.appearance = nil;
	}
	// 跟着所有空间跑、全屏时也留着、不进 Cmd+Tab 和窗口循环
	_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
	                            NSWindowCollectionBehaviorFullScreenAuxiliary |
	                            NSWindowCollectionBehaviorStationary |
	                            NSWindowCollectionBehaviorIgnoresCycle;

	// 层级名 → NSWindowLevel，认不出的名字按 floating
	NSString *level = [config.level lowercaseString];
	if ([level isEqualToString:@"status"] || [level isEqualToString:@"statusbar"]) {
		_panel.level = NSStatusWindowLevel;
	} else if ([level isEqualToString:@"screensaver"]) {
		_panel.level = NSScreenSaverWindowLevel;
	} else if ([level isEqualToString:@"normal"]) {
		_panel.level = NSNormalWindowLevel;
	} else {
		_panel.level = NSFloatingWindowLevel;
	}

	return self;
}

- (void)animateAlpha:(CGFloat)alpha
               frame:(NSRect)frame
                move:(BOOL)move
            duration:(double)duration
          completion:(dispatch_block_t)completion {
	[self cancelAnimation];

	NSWindow *window = self.panel;
	// 还没上屏时没有可动画的帧，直接跳到终值，免得空转一整段计时器
	if (duration <= 0 || !window.isVisible) {
		window.alphaValue = alpha;
		if (move) [window setFrame:frame display:YES];
		if (completion) completion();
		return;
	}

	self.animStep = 0;
	self.animSteps = MAX(1, (NSInteger)(duration * 60.0));
	self.animStartAlpha = window.alphaValue;
	self.animTargetAlpha = alpha;
	self.animStartFrame = window.frame;
	self.animTargetFrame = frame;
	self.animMove = move;
	self.animCompletion = completion;

	// 用 NSTimer 而不是 dispatch source：回调里 invalidate 是受支持的做法，也不会有 source 与 handler 自引用成环
	self.animTimer = [NSTimer scheduledTimerWithTimeInterval:duration / (double)self.animSteps
	                                                  target:self
	                                                selector:@selector(stepAnimation:)
	                                                userInfo:nil
	                                                 repeats:YES];
}

- (void)stepAnimation:(NSTimer *)timer {
	self.animStep += 1;
	double t = MIN(1.0, (double)self.animStep / (double)self.animSteps);
	// 三次缓出，收尾比线性缓，手感接近系统通知
	double eased = 1.0 - pow(1.0 - t, 3.0);

	NSWindow *window = self.panel;
	window.alphaValue = self.animStartAlpha + (self.animTargetAlpha - self.animStartAlpha) * (CGFloat)eased;
	if (self.animMove) {
		NSRect s = self.animStartFrame;
		NSRect d = self.animTargetFrame;
		[window setFrame:NSMakeRect(s.origin.x + (d.origin.x - s.origin.x) * eased,
		                            s.origin.y + (d.origin.y - s.origin.y) * eased,
		                            d.size.width,
		                            d.size.height)
		         display:YES];
	}

	if (t < 1.0) return;

	[timer invalidate];
	self.animTimer = nil;
	dispatch_block_t done = self.animCompletion;
	self.animCompletion = nil;
	if (done) done();
}

- (void)cancelAnimation {
	[self.animTimer invalidate];
	self.animTimer = nil;
	self.animCompletion = nil;
}

- (void)dealloc {
	if (getenv("TOAST_DEBUG")) fprintf(stderr, "toast: item dealloc %p\n", self);
}

- (void)scheduleWithDuration:(double)duration action:(dispatch_block_t)action {
	[self cancelTimer];
	// generation 用来作废已排队的旧计时器：取消不保证能拦住已经在队列里的 block
	int generation = ++_generation;
	__weak ToastItem *weakSelf = self;
	dispatch_block_t block = dispatch_block_create(0, ^{
		ToastItem *item = weakSelf;
		if (getenv("TOAST_DEBUG")) fprintf(stderr, "toast: timer fire gen=%d item=%p\n", generation, item);
		if (!item || item.generation != generation) return;
		action();
	});
	if (getenv("TOAST_DEBUG")) fprintf(stderr, "toast: schedule %.2fs gen=%d\n", duration, generation);
	_dismissBlock = block;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), block);
}

- (void)cancelTimer {
	_generation += 1;
	if (_dismissBlock) {
		dispatch_block_cancel(_dismissBlock);
		_dismissBlock = nil;
	}
}

@end
