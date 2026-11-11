#import "CardView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

#pragma mark - 排版

static NSAttributedString *StyledText(NSString *text, NSFont *font, NSColor *color, CGFloat lineSpacing) {
	// 行距交给段落样式，上下留白由卡片自己算
	NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
	p.lineSpacing = lineSpacing;
	return [[NSAttributedString alloc] initWithString:(text ?: @"")
	                                       attributes:@{
		                                       NSFontAttributeName : font,
		                                       NSForegroundColorAttributeName : color,
		                                       NSParagraphStyleAttributeName : p,
	                                       }];
}

static CGFloat TextHeight(NSAttributedString *text, NSFont *font, CGFloat lineSpacing, CGFloat width, int maxLines) {
	// 按行高整数倍估算行数再压到 maxLines，直接取 boundingRect 会因字形下伸多算半行
	if (width <= 1 || text.length == 0) return 0;
	CGFloat lineHeight = ceil(font.ascender - font.descender + font.leading) + lineSpacing;
	NSRect rect = [text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
	                                 options:NSStringDrawingUsesLineFragmentOrigin |
	                                         NSStringDrawingUsesFontLeading];
	int lines = (int)ceil(rect.size.height / lineHeight);
	if (lines < 1) lines = 1;
	if (lines > maxLines) lines = maxLines;
	return lines * lineHeight;
}

#pragma mark - 装饰视图

// 纯装饰，不能吞掉点击
@interface DecorView : NSView
@end

@implementation DecorView
- (NSView *)hitTest:(NSPoint)point {
	return nil;
}
@end

// 顶部落一层白光：桌面纯黑时背后没有东西可模糊，卡片得自带高光才像玻璃
@interface SheenView : NSView
- (instancetype)initWithFrame:(NSRect)frame sheen:(CGFloat)sheen radius:(CGFloat)radius;
@end

@implementation SheenView {
	CAGradientLayer *_gradient;
}

- (NSView *)hitTest:(NSPoint)point {
	return nil;
}

- (instancetype)initWithFrame:(NSRect)frame sheen:(CGFloat)sheen radius:(CGFloat)radius {
	self = [super initWithFrame:frame];
	if (!self || sheen <= 0) return self;
	self.wantsLayer = YES;
	self.layer.cornerRadius = radius;
	self.layer.cornerCurve = kCACornerCurveContinuous;
	self.layer.masksToBounds = YES;

	// 收得紧的一道光才像玻璃，铺开的渐变只会把整张卡涂灰
	_gradient = [CAGradientLayer layer];
	_gradient.colors = @[
		(id)[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:sheen].CGColor,
		(id)[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:sheen * 0.45].CGColor,
		(id)[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:sheen * 0.10].CGColor,
		(id)[NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:0].CGColor,
	];
	_gradient.locations = @[ @0.0, @0.08, @0.45, @1.0 ];
	_gradient.startPoint = CGPointMake(0.5, 1.0);
	_gradient.endPoint = CGPointMake(0.5, 0.0);
	[self.layer addSublayer:_gradient];
	return self;
}

- (void)layout {
	[super layout];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_gradient.frame = self.bounds;
	[CATransaction commit];
}

@end

// 用 maskImage 塑形；layer 的 cornerRadius + masksToBounds 会把背景模糊一起吞掉
static NSImage *RoundedMask(CGFloat radius) {
	CGFloat edge = floor(radius * 2.0) + 1.0;
	NSImage *image = [NSImage imageWithSize:NSMakeSize(edge, edge)
	                                 flipped:NO
	                          drawingHandler:^BOOL(NSRect rect) {
		                          NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
		                                                                              xRadius:radius
		                                                                              yRadius:radius];
		                          [NSColor.blackColor setFill];
		                          [path fill];
		                          return YES;
	                          }];
	image.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
	image.resizingMode = NSImageResizingModeStretch;
	return image;
}

// 顶部收光的细边，压在最上层
@interface RimView : NSView
- (instancetype)initWithFrame:(NSRect)frame radius:(CGFloat)radius width:(CGFloat)width color:(NSColor *)color;
@end

@implementation RimView {
	CAGradientLayer *_gradient;
	CAShapeLayer *_mask;
}

- (NSView *)hitTest:(NSPoint)point {
	return nil;
}

- (instancetype)initWithFrame:(NSRect)frame radius:(CGFloat)radius width:(CGFloat)width color:(NSColor *)color {
	self = [super initWithFrame:frame];
	if (!self || width <= 0) return self;
	self.wantsLayer = YES;

	CGRect box = NSInsetRect(self.bounds, width / 2.0, width / 2.0);
	NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:box
	                                                    xRadius:MAX(radius - width / 2.0, 0)
	                                                    yRadius:MAX(radius - width / 2.0, 0)];
	_mask = [CAShapeLayer layer];
	_mask.path = path.CGPath;
	_mask.fillColor = nil;
	_mask.strokeColor = NSColor.blackColor.CGColor;
	_mask.lineWidth = width;

	_gradient = [CAGradientLayer layer];
	CGFloat base = color.alphaComponent;
	_gradient.colors = @[
		(id)[color colorWithAlphaComponent:MIN(base * 2.6, 1.0)].CGColor,
		(id)[color colorWithAlphaComponent:base * 0.75].CGColor,
		(id)[color colorWithAlphaComponent:base * 0.45].CGColor,
	];
	_gradient.locations = @[ @0.0, @0.45, @1.0 ];
	_gradient.startPoint = CGPointMake(0.5, 1.0);
	_gradient.endPoint = CGPointMake(0.5, 0.0);
	_gradient.mask = _mask;
	[self.layer addSublayer:_gradient];
	return self;
}

- (void)layout {
	[super layout];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_gradient.frame = self.bounds;
	CGRect box = NSInsetRect(self.bounds, _mask.lineWidth / 2.0, _mask.lineWidth / 2.0);
	CGFloat radius = MAX(self.layer.cornerRadius, 0);
	_mask.path = [NSBezierPath bezierPathWithRoundedRect:box
	                                            xRadius:radius
	                                            yRadius:radius].CGPath;
	[CATransaction commit];
}

@end

// 原点在左上，自上而下排版不用换算
@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped {
	return YES;
}
@end

#pragma mark - 卡片

@interface ToastCardView ()
@property (nonatomic) CGFloat cardHeight;
@end

@implementation ToastCardView {
	ToastConfig *_config;
	NSVisualEffectView *_fx;
	NSView *_content;
	DecorView *_tint;
	DecorView *_accent;
	NSTextField *_titleField;
	NSTextField *_bodyField;
	NSTrackingArea *_tracking;
	BOOL _hovering;
	CGFloat _titleHeight;
	CGFloat _bodyHeight;
	BOOL _showTitle;
	BOOL _showBody;
	CGFloat _textX;
}

- (BOOL)isFlipped {
	return YES;
}

- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config {
	self = [super initWithFrame:NSZeroRect];
	if (!self) return nil;
	_config = config;
	self.wantsLayer = YES;

	NSFont *titleFont = [NSFont systemFontOfSize:config.titleSize weight:config.titleWeight];
	NSFont *bodyFont = [NSFont systemFontOfSize:config.bodySize weight:config.bodyWeight];
	NSString *title = payload.title ?: @"";
	NSString *body = payload.body ?: @"";
	_showTitle = config.showTitle && title.length > 0;
	_showBody = config.showBody && body.length > 0;

	// 强调件与其后的空隙由标题行共用，两种样式下正文左边界始终对齐
	NSString *accentStyle = [config.accentStyle lowercaseString];
	BOOL hasAccent = _showTitle && ![accentStyle isEqualToString:@"none"];
	CGFloat accentSize = [accentStyle isEqualToString:@"bar"] ? config.accentWidth : config.dotSize;
	// 强调件比正文缩进再往里一点：胶囊越圆，贴在 paddingX 上的点越显得被挤
	CGFloat accentX = config.paddingX + config.accentInset;
	_textX = hasAccent ? accentX + accentSize + config.dotGap : config.paddingX;
	CGFloat textWidth = config.width - _textX - config.paddingX;

	BOOL dark = config.isDarkMode;
	NSAttributedString *titleText =
	    StyledText(title, titleFont, [config.titleColor colorForDark:dark], config.lineSpacing);
	NSAttributedString *bodyText =
	    StyledText(body, bodyFont, [config.bodyColor colorForDark:dark], config.lineSpacing);

	_titleHeight = _showTitle ? TextHeight(titleText, titleFont, config.lineSpacing, textWidth, config.maxTitleLines) : 0;
	_bodyHeight = _showBody ? TextHeight(bodyText, bodyFont, config.lineSpacing, textWidth, config.maxBodyLines) : 0;

	CGFloat gap = (_titleHeight > 0 && _bodyHeight > 0) ? config.titleBodyGap : 0;
	// 卡片高度先由排版算出来，capsule 的圆角依赖它
	CGFloat height = config.paddingY * 2 + _titleHeight + gap + _bodyHeight;
	if (_titleHeight == 0 && _bodyHeight == 0) {
		height = config.paddingY * 2 + ceil(titleFont.ascender - titleFont.descender);
	}
	self.cardHeight = MAX(height, 36);
	self.frame = NSMakeRect(0, 0, config.width, self.cardHeight);

	CGFloat radius = config.cornerRadiusAuto ? self.cardHeight / 2.0 : config.cornerRadius;
	NSAutoresizingMaskOptions fill = NSViewWidthSizable | NSViewHeightSizable;

	_content = [[FlippedView alloc] initWithFrame:self.bounds];
	_content.autoresizingMask = fill;

	// 1. 背景。macOS 26 的 NSGlassEffectView 是真正的 Liquid Glass，NSVisualEffectView 是老系统退路
	NSString *materialName = [config.material lowercaseString];
	BOOL materialOff = [materialName isEqualToString:@"none"];
	// 前缀 classic 强制走旧版 vibrancy
	BOOL forceClassic = [materialName hasPrefix:@"classic"];
	BOOL glassUsed = NO;

	if (!materialOff && !forceClassic) {
		if (@available(macOS 26.0, *)) {
			if (NSClassFromString(@"NSGlassEffectView")) {
				NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
				glass.cornerRadius = radius;
				glass.tintColor = [config.background colorForDark:dark];
				glass.style = [materialName isEqualToString:@"clear"] ? NSGlassEffectViewStyleClear
				                                                     : NSGlassEffectViewStyleRegular;
				glass.autoresizingMask = fill;
				glass.contentView = _content;
				[self addSubview:glass];
				glassUsed = YES;
				if (getenv("TOAST_DEBUG")) fprintf(stderr, "toast: background=glass radius=%.1f\n", radius);
			}
		}
	}

	if (!materialOff && !glassUsed) {
		NSString *fxName = forceClassic ? [materialName stringByReplacingOccurrencesOfString:@"classic:" withString:@""]
		                               : materialName;
		if ([fxName isEqualToString:@"classic"] || fxName.length == 0) fxName = @"hudWindow";
		_fx = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
		_fx.material = [ToastCardView materialNamed:fxName];
		_fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
		_fx.state = NSVisualEffectStateActive;
		_fx.maskImage = RoundedMask(radius);
		_fx.autoresizingMask = fill;
		[self addSubview:_fx];
	}

	// 2. 兜底底色 + 高光。玻璃自带高光，再叠一层只会把材质压平
	if (!glassUsed) {
		_tint = [[DecorView alloc] initWithFrame:self.bounds];
		_tint.wantsLayer = YES;
		_tint.layer.backgroundColor = [config.background cgColorForDark:dark];
		_tint.layer.cornerRadius = radius;
		_tint.layer.cornerCurve = kCACornerCurveContinuous;
		_tint.layer.masksToBounds = YES;
		_tint.autoresizingMask = fill;
		[self addSubview:_tint];

		if (config.sheen > 0) {
			SheenView *sheen = [[SheenView alloc] initWithFrame:self.bounds sheen:config.sheen radius:radius];
			sheen.autoresizingMask = fill;
			[self addSubview:sheen];
		}
		// 内容视图只能挂这一次：无条件 addSubview 会把它从 glass.contentView 里拽出来
		[self addSubview:_content];
	}

	// 3. 强调件：标题行上的圆点，或沿文字块向下的竖条
	if (hasAccent) {
		_accent = [[DecorView alloc] initWithFrame:NSZeroRect];
		_accent.wantsLayer = YES;
		_accent.layer.backgroundColor = [config.accentColor cgColorForDark:dark];
		CGFloat blockHeight = _titleHeight + gap + _bodyHeight;
		if ([accentStyle isEqualToString:@"bar"]) {
			_accent.frame = NSMakeRect(accentX, config.paddingY + 1, accentSize, MAX(blockHeight - 2, accentSize));
		} else {
			CGFloat y;
			if ([[config.accentAlign lowercaseString] isEqualToString:@"title"]) {
				CGFloat titleLine = ceil(titleFont.ascender - titleFont.descender + titleFont.leading);
				y = config.paddingY + (titleLine - accentSize) / 2.0;
			} else {
				// 居中对齐文字块：胶囊高起来后，贴着标题行的点会像一颗走失的圆点
				y = (config.paddingY * 2 + blockHeight - accentSize) / 2.0;
			}
			_accent.frame = NSMakeRect(accentX, y, accentSize, accentSize);
		}
		_accent.layer.cornerRadius = accentSize / 2.0;
		[_content addSubview:_accent];
	}

	// 4. 文字
	_titleField = [NSTextField labelWithString:@""];
	_bodyField = [NSTextField labelWithString:@""];
	[self configureField:_titleField text:titleText maxLines:config.maxTitleLines];
	[self configureField:_bodyField text:bodyText maxLines:config.maxBodyLines];
	_titleField.hidden = !_showTitle;
	_bodyField.hidden = !_showBody;
	[_content addSubview:_titleField];
	[_content addSubview:_bodyField];

	// 5. 描边放最后，盖在材质之上
	if (config.borderWidth > 0) {
		RimView *rim = [[RimView alloc] initWithFrame:self.bounds
		                                     radius:radius
		                                      width:config.borderWidth
		                                      color:[config.borderColor colorForDark:dark]];
		rim.layer.cornerRadius = radius;
		rim.autoresizingMask = fill;
		[self addSubview:rim];
	}

	return self;
}

+ (NSVisualEffectMaterial)materialNamed:(NSString *)name {
	NSString *n = [name lowercaseString];
	if ([n isEqualToString:@"popover"]) return NSVisualEffectMaterialPopover;
	if ([n isEqualToString:@"menu"]) return NSVisualEffectMaterialMenu;
	if ([n isEqualToString:@"sidebar"]) return NSVisualEffectMaterialSidebar;
	if ([n isEqualToString:@"content"]) return NSVisualEffectMaterialContentBackground;
	if ([n isEqualToString:@"underwindow"]) return NSVisualEffectMaterialUnderWindowBackground;
	return NSVisualEffectMaterialHUDWindow;
}

- (void)configureField:(NSTextField *)field text:(NSAttributedString *)text maxLines:(int)maxLines {
	// 可编辑、可选、带背景全部关掉，只当一个排版容器用
	field.attributedStringValue = text;
	field.editable = NO;
	field.selectable = NO;
	field.bezeled = NO;
	field.drawsBackground = NO;
	field.bordered = NO;
	field.maximumNumberOfLines = maxLines;
	field.lineBreakMode = NSLineBreakByTruncatingTail;
	field.cell.wraps = YES;
	field.cell.scrollable = NO;
	field.alignment = NSTextAlignmentLeft;
}

- (void)layout {
	[super layout];
	ToastConfig *c = _config;
	_content.frame = self.bounds;
	// 自上而下排：标题占一行高度，正文接在后面，两者都空时只剩上下留白
	CGFloat w = self.bounds.size.width - _textX - c.paddingX;
	CGFloat y = c.paddingY;
	if (!_titleField.hidden) {
		_titleField.frame = NSMakeRect(_textX, y, w, _titleHeight);
		y += _titleHeight;
	}
	if (!_bodyField.hidden) {
		if (!_titleField.hidden) y += c.titleBodyGap;
		_bodyField.frame = NSMakeRect(_textX, y, w, _bodyHeight);
	}
}

#pragma mark - 悬停

- (void)updateTrackingAreas {
	[super updateTrackingAreas];
	if (_tracking) [self removeTrackingArea:_tracking];
	_tracking = [[NSTrackingArea alloc]
	    initWithRect:self.bounds
	         options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways |
	                  NSTrackingInVisibleRect)
	           owner:self
	        userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event {
	if (!_config.hoverEnabled) return;
	_hovering = YES;
	[self applyTilt:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event {
	_hovering = NO;
	[self applyTilt:NSZeroPoint];
}

- (void)mouseMoved:(NSEvent *)event {
	if (!_config.hoverEnabled || !_hovering) return;
	[self applyTilt:[self convertPoint:event.locationInWindow fromView:nil]];
}

// 朝光标倾斜，带一点缩放和上浮；变换绕图层中心做，anchorPoint 保持 AppKit 的默认值
- (void)applyTilt:(NSPoint)point {
	ToastConfig *c = _config;
	CGFloat w = MAX(self.bounds.size.width, 1);
	CGFloat h = MAX(self.bounds.size.height, 1);
	CGFloat nx = _hovering ? (point.x / w - 0.5) * 2.0 : 0.0;
	CGFloat ny = _hovering ? (point.y / h - 0.5) * 2.0 : 0.0;

	CGFloat radians = (CGFloat)M_PI / 180.0;
	CGFloat tilt = _hovering ? c.hoverTilt : 0.0;
	CGFloat scale = _hovering ? c.hoverScale : 1.0;
	CGFloat lift = _hovering ? c.hoverLift : 0.0;

	CATransform3D t = CATransform3DIdentity;
	t.m34 = -1.0 / 500.0;
	t = CATransform3DTranslate(t, w / 2.0, h / 2.0, 0);
	t = CATransform3DRotate(t, -nx * tilt * radians, 0, 1, 0);
	t = CATransform3DRotate(t, ny * tilt * radians, 1, 0, 0);
	t = CATransform3DScale(t, scale, scale, 1);
	t = CATransform3DTranslate(t, -w / 2.0, -h / 2.0 - lift, 0);

	[CATransaction begin];
	[CATransaction setAnimationDuration:(_hovering ? c.hoverDuration : 0.22)];
	[CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
	[CATransaction setDisableActions:NO];
	self.layer.transform = t;
	[CATransaction commit];
	[self.window invalidateShadow];
}

- (void)mouseDown:(NSEvent *)event {
	if (_onDismiss) _onDismiss();
}

- (void)rightMouseDown:(NSEvent *)event {
	if (_onDismiss) _onDismiss();
}

@end
