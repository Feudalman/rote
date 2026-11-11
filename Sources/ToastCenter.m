#import "ToastCenter.h"
#import "ToastItem.h"

@interface ToastCenter ()
@property (nonatomic) ToastConfig *config;
@property (nonatomic) NSMutableArray<ToastItem *> *items;
@end

@implementation ToastCenter

- (instancetype)initWithConfig:(ToastConfig *)config {
	self = [super init];
	if (!self) return nil;
	_config = config;
	_items = [NSMutableArray array];
	return self;
}

// main | mouse | 屏序号 "0"/"1"/"2" | 屏名字片段
- (NSScreen *)screenFor:(NSString *)name {
	NSString *key = [name lowercaseString];
	NSArray<NSScreen *> *screens = NSScreen.screens;

	if ([key isEqualToString:@"mouse"]) {
		NSPoint p = NSEvent.mouseLocation;
		for (NSScreen *s in screens) {
			if (NSMouseInRect(p, s.frame, NO)) return s;
		}
		return screens.firstObject ?: NSScreen.mainScreen;
	}
	// NSScreen.mainScreen 跟着 key window 跑，accessory app 没有 key window 时会退化成跟鼠标，
	// 所以 main 一律取 screens[0]，也就是有菜单栏那块
	if (key.length == 0 || [key isEqualToString:@"main"]) return screens.firstObject ?: NSScreen.mainScreen;

	NSInteger index = key.integerValue;
	if (index >= 0 && index < (NSInteger)screens.count &&
	    [key isEqualToString:[NSString stringWithFormat:@"%ld", (long)index]]) {
		return screens[index];
	}
	for (NSScreen *s in screens) {
		if ([s.localizedName.lowercaseString containsString:key]) return s;
	}
	return screens.firstObject ?: NSScreen.mainScreen;
}

- (void)present:(ToastPayload *)payload {
	ToastItem *item = [[ToastItem alloc] initWithPayload:payload config:self.config];
	// payload 里的 screen 覆盖全局配置
	item.screen = [self screenFor:(payload.screen.length ? payload.screen : self.config.screen)];

	__weak ToastCenter *weakSelf = self;
	__weak ToastItem *weakItem = item;
	item.card.onDismiss = ^{
		ToastCenter *center = weakSelf;
		ToastItem *target = weakItem;
		if (center && target) [center dismiss:target];
	};
	// 数组头部就是屏幕最上面那条，新的一条总在最前
	[self.items insertObject:item atIndex:0];

	// 超出 maxVisible 从最旧的开始摘，直接关窗口不做淡出，免得屏上同时堆一叠
	int maxVisible = MAX(self.config.maxVisible, 1);
	while ((int)self.items.count > maxVisible) {
		ToastItem *oldest = self.items.lastObject;
		[self.items removeLastObject];
		[oldest cancelTimer];
		[oldest.panel orderOut:nil];
		[oldest.panel close];
	}

	// 先以全透明上屏再淡入，避免出现一帧硬边卡片
	item.panel.alphaValue = 0;
	[item.panel orderFront:nil];
	[self layoutItems];
	[item animateAlpha:1 frame:item.panel.frame move:NO duration:self.config.fadeIn completion:nil];

	double duration = payload.duration ? payload.duration.doubleValue : self.config.duration;
	[item scheduleWithDuration:duration
	                    action:^{
		                    ToastCenter *center = weakSelf;
		                    ToastItem *target = weakItem;
		                    if (center && target) [center dismiss:target];
	                    }];
}

- (void)dismiss:(ToastItem *)item {
	NSUInteger index = [self.items indexOfObjectIdenticalTo:item];
	if (index == NSNotFound) return;
	[self.items removeObjectAtIndex:index];
	[item cancelTimer];

	// 面板要活到淡出结束：item 已从列表里摘掉，可能在 completion 之前就被释放
	NSPanel *panel = item.panel;
	[item animateAlpha:0
	              frame:panel.frame
	               move:NO
	           duration:self.config.fadeOut
	         completion:^{
		           [panel orderOut:nil];
		           [panel close];
	         }];

	[self layoutItems];
}

- (void)layoutItems {
	// 重排是瞬时的，不碰 alpha：在这里打断进行中的淡入，正是新排队的卡片卡在 alpha 0 的原因
	ToastConfig *c = self.config;
	// 一块屏一个游标：记下该屏下一条可选位置的 y 值
	NSMutableDictionary<NSNumber *, NSNumber *> *cursor = [NSMutableDictionary dictionary];

	for (ToastItem *item in self.items) {
		NSScreen *screen = item.screen ?: NSScreen.screens.firstObject;
		NSNumber *key = @([NSScreen.screens indexOfObject:screen]);
		NSRect visible = screen.visibleFrame;

		CGFloat y = cursor[key] ? cursor[key].doubleValue : NSMaxY(visible) - c.marginTop;
		// 从可见区域顶部往下排，每条之间留 spacing
		y -= item.card.cardHeight;
		cursor[key] = @(y - c.spacing);

		CGFloat x;
		NSString *align = [c.align lowercaseString];
		if ([align isEqualToString:@"left"]) {
			x = NSMinX(visible) + c.marginLeft;
		} else if ([align isEqualToString:@"center"]) {
			x = NSMidX(visible) - c.width / 2.0;
		} else {
			x = NSMaxX(visible) - c.marginRight - c.width;
		}

		CGFloat gutter = c.hoverEnabled ? MAX(c.hoverMargin, 0) : 0;
		[item.panel setFrame:NSMakeRect(x - gutter, y - gutter, c.width + gutter * 2, item.card.cardHeight + gutter * 2)
		             display:YES];
	}
}

@end
