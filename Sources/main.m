// toast — a tiny macOS toast notifier (demo v1)
//
//   toast serve [--config PATH]        run the resident toast server (default)
//   toast send --title T --body B      push one toast over the unix socket
//   toast send --json '{...}'          push a raw JSON payload
//   toast send                         read a JSON payload from stdin
//   toast config                       print resolved config
//
// Protocol: one JSON object per line over a unix stream socket:
//   {"title": "...", "body": "...", "duration": 3, "source": "pi"}
// Unknown fields are ignored; a non-JSON line is rendered as the body.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <math.h>
#include <unistd.h>

#pragma mark - Paths & config helpers

static NSString *ExpandTilde(NSString *path) {
	if (![path hasPrefix:@"~"]) return path;
	return [NSHomeDirectory() stringByAppendingPathComponent:[path substringFromIndex:1]];
}

static NSColor *HexColor(NSString *hex, NSColor *fallback) {
	if (![hex isKindOfClass:NSString.class]) return fallback;
	NSString *s = [[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
		stringByReplacingOccurrencesOfString:@"#" withString:@""];
	if ([s length] != 6 && [s length] != 8) return fallback;
	unsigned long long v = 0;
	NSScanner *scanner = [NSScanner scannerWithString:s];
	if (![scanner scanHexLongLong:&v] || !scanner.isAtEnd) return fallback;
	BOOL hasAlpha = [s length] == 8;
	double r = (double)((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0;
	double g = (double)((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0;
	double b = (double)((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0;
	double a = hasAlpha ? (double)(v & 0xFF) / 255.0 : 1.0;
	return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

static NSFontWeight ParseWeight(NSString *name) {
	NSString *w = [name lowercaseString];
	if ([w isEqualToString:@"ultralight"]) return NSFontWeightUltraLight;
	if ([w isEqualToString:@"thin"]) return NSFontWeightThin;
	if ([w isEqualToString:@"light"]) return NSFontWeightLight;
	if ([w isEqualToString:@"medium"]) return NSFontWeightMedium;
	if ([w isEqualToString:@"semibold"]) return NSFontWeightSemibold;
	if ([w isEqualToString:@"bold"]) return NSFontWeightBold;
	if ([w isEqualToString:@"heavy"]) return NSFontWeightHeavy;
	if ([w isEqualToString:@"black"]) return NSFontWeightBlack;
	return NSFontWeightRegular;
}

static NSDictionary *ConfigObject(NSDictionary *dict, NSString *key) {
	id v = dict[key];
	return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

static double ConfigNum(NSDictionary *dict, NSString *key, double fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}

static int ConfigInt(NSDictionary *dict, NSString *key, int fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v intValue] : fallback;
}

static BOOL ConfigBool(NSDictionary *dict, NSString *key, BOOL fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}

static NSString *ConfigStr(NSDictionary *dict, NSString *key, NSString *fallback) {
	id v = dict[key];
	if ([v isKindOfClass:NSString.class] && [v length] > 0) return v;
	return fallback;
}

static NSAttributedString *StyledText(NSString *text, NSFont *font, NSColor *color, CGFloat lineSpacing) {
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

#pragma mark - Themed colour

// A colour that can vary per appearance. Config accepts either a plain hex string
// (same in both modes) or {"light": "#..", "dark": "#.."}.
@interface ThemeColor : NSObject
@property (nonatomic) NSColor *light;
@property (nonatomic) NSColor *dark;
- (NSColor *)colorForDark:(BOOL)dark;
- (CGColorRef)cgColorForDark:(BOOL)dark;
@end

@implementation ThemeColor
- (NSColor *)colorForDark:(BOOL)dark {
	return dark ? (self.dark ?: self.light) : (self.light ?: self.dark);
}
- (CGColorRef)cgColorForDark:(BOOL)dark {
	return [self colorForDark:dark].CGColor;
}
@end

static ThemeColor *ConfigColor(NSDictionary *dict, NSString *key, NSString *darkHex, NSString *lightHex) {
	id value = dict[key];
	ThemeColor *c = [ThemeColor new];
	NSColor *darkFallback = HexColor(darkHex, [NSColor colorWithSRGBRed:1 green:1 blue:1 alpha:1]);
	NSColor *lightFallback = HexColor(lightHex, [NSColor colorWithSRGBRed:0 green:0 blue:0 alpha:1]);

	if ([value isKindOfClass:NSDictionary.class]) {
		c.dark = HexColor(((NSDictionary *)value)[@"dark"], darkFallback);
		c.light = HexColor(((NSDictionary *)value)[@"light"], lightFallback);
	} else if ([value isKindOfClass:NSString.class]) {
		NSColor *single = HexColor(value, darkFallback);
		c.dark = single;
		c.light = single;
	} else {
		c.dark = darkFallback;
		c.light = lightFallback;
	}
	return c;
}

#pragma mark - Config

@interface ToastConfig : NSObject

@property (nonatomic) NSString *configPath;
@property (nonatomic) NSString *socketPath;

@property (nonatomic) CGFloat width, marginTop, marginRight, spacing, cornerRadius;
@property (nonatomic) BOOL cornerRadiusAuto;
@property (nonatomic) CGFloat paddingX, paddingY, accentWidth, borderWidth;
@property (nonatomic) CGFloat titleSize, bodySize, titleBodyGap, lineSpacing;
@property (nonatomic) CGFloat dotSize, dotGap, accentInset;
@property (nonatomic) NSString *accentAlign;
@property (nonatomic) NSString *accentStyle, *material, *theme;
@property (nonatomic) int maxTitleLines, maxBodyLines;
@property (nonatomic) ThemeColor *accentColor, *background, *borderColor, *titleColor, *bodyColor;
@property (nonatomic) NSFontWeight titleWeight, bodyWeight;
@property (nonatomic) BOOL shadow;
@property (nonatomic) CGFloat sheen;
@property (nonatomic) BOOL hoverEnabled;
@property (nonatomic) CGFloat hoverTilt, hoverScale, hoverLift, hoverDuration, hoverMargin;

@property (nonatomic) double duration, fadeIn, fadeOut;
@property (nonatomic) int maxVisible;
@property (nonatomic) BOOL clickToDismiss;
@property (nonatomic) NSString *level, *screen, *align;
@property (nonatomic) CGFloat marginLeft;

@property (nonatomic) BOOL showTitle, showBody;

@end

@implementation ToastConfig

+ (instancetype)loadFromPath:(NSString *)explicitPath {
	NSString *path = explicitPath;
	if (!path) path = NSProcessInfo.processInfo.environment[@"PI_TOAST_CONFIG"];
	if (!path) path = @"~/.config/pi-toast/config.json";
	path = ExpandTilde(path);

	NSDictionary *root = @{};
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data) {
		id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		if ([parsed isKindOfClass:NSDictionary.class]) root = parsed;
	}

	ToastConfig *c = [ToastConfig new];
	c.configPath = path;
	c.socketPath = ExpandTilde(ConfigStr(root, @"socket", @"~/.pi-toast/toast.sock"));

	NSDictionary *a = ConfigObject(root, @"appearance");
	c.width = ConfigNum(a, @"width", 340);
	c.marginTop = ConfigNum(a, @"marginTop", 14);
	c.marginRight = ConfigNum(a, @"marginRight", 14);
	c.spacing = ConfigNum(a, @"spacing", 8);
	// "cornerRadius": "capsule" always means half the card height, so the shape keeps
	// its proportion when the body wraps to two lines.
	id cornerValue = a[@"cornerRadius"];
	c.cornerRadiusAuto = [cornerValue isKindOfClass:NSString.class];
	c.cornerRadius = c.cornerRadiusAuto ? 0 : ConfigNum(a, @"cornerRadius", 33);
	c.paddingX = ConfigNum(a, @"paddingX", 16);
	c.paddingY = ConfigNum(a, @"paddingY", 13);
	c.accentWidth = ConfigNum(a, @"accentWidth", 3);
	c.accentStyle = ConfigStr(a, @"accentStyle", @"dot");
	c.material = ConfigStr(a, @"material", @"hudWindow");
	c.theme = ConfigStr(a, @"theme", @"dark");
	c.dotSize = ConfigNum(a, @"dotSize", 8);
	c.dotGap = ConfigNum(a, @"dotGap", 10);
	c.accentInset = ConfigNum(a, @"accentInset", 6);
	c.accentAlign = ConfigStr(a, @"accentAlign", @"center");
	c.lineSpacing = ConfigNum(a, @"lineSpacing", 1);
	c.borderWidth = ConfigNum(a, @"borderWidth", 1);
	c.titleSize = ConfigNum(a, @"titleSize", 13);
	c.bodySize = ConfigNum(a, @"bodySize", 12);
	c.titleBodyGap = ConfigNum(a, @"titleBodyGap", 4);
	c.maxTitleLines = ConfigInt(a, @"maxTitleLines", 2);
	c.maxBodyLines = ConfigInt(a, @"maxBodyLines", 3);
	c.accentColor = ConfigColor(a, @"accentColor", @"#4ADE80", @"#16A34A");
	c.background = ConfigColor(a, @"background", @"#FFFFFF12", @"#F2F2F4E6");
	c.borderColor = ConfigColor(a, @"borderColor", @"#FFFFFF1F", @"#00000014");
	c.titleColor = ConfigColor(a, @"titleColor", @"#FFFFFFF5", @"#000000E6");
	c.bodyColor = ConfigColor(a, @"bodyColor", @"#FFFFFF99", @"#0000008C");
	c.titleWeight = ParseWeight(ConfigStr(a, @"titleWeight", @"semibold"));
	c.bodyWeight = ParseWeight(ConfigStr(a, @"bodyWeight", @"regular"));
	c.shadow = ConfigBool(a, @"shadow", YES);
	c.sheen = ConfigNum(a, @"sheen", 0.10);
	c.hoverMargin = ConfigNum(a, @"hoverMargin", 12);
	NSDictionary *h = ConfigObject(a, @"hover");
	c.hoverEnabled = ConfigBool(h, @"enabled", YES);
	c.hoverTilt = ConfigNum(h, @"tilt", 9);
	c.hoverScale = ConfigNum(h, @"scale", 1.03);
	c.hoverLift = ConfigNum(h, @"lift", 2);
	c.hoverDuration = ConfigNum(h, @"duration", 0.12);

	NSDictionary *b = ConfigObject(root, @"behavior");
	c.duration = ConfigNum(b, @"duration", 10);
	c.fadeIn = ConfigNum(b, @"fadeIn", 0.16);
	c.fadeOut = ConfigNum(b, @"fadeOut", 0.22);
	c.maxVisible = ConfigInt(b, @"maxVisible", 4);
	c.clickToDismiss = ConfigBool(b, @"clickToDismiss", YES);
	c.level = ConfigStr(b, @"level", @"floating");
	c.screen = ConfigStr(b, @"screen", @"main");
	c.align = ConfigStr(b, @"align", @"center");
	c.marginLeft = ConfigNum(a, @"marginLeft", 14);

	NSDictionary *ct = ConfigObject(root, @"content");
	c.showTitle = ConfigBool(ct, @"showTitle", YES);
	c.showBody = ConfigBool(ct, @"showBody", YES);

	return c;
}

- (BOOL)isDarkMode {
	NSString *theme = [self.theme lowercaseString];
	if ([theme isEqualToString:@"dark"]) return YES;
	if ([theme isEqualToString:@"light"]) return NO;
	NSAppearanceName name = [NSApp.effectiveAppearance
	    bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
	return [name isEqualToString:NSAppearanceNameDarkAqua];
}

- (BOOL)hasConfigFile {
	return [NSFileManager.defaultManager fileExistsAtPath:self.configPath];
}

@end

#pragma mark - Payload

@interface ToastPayload : NSObject
@property (nonatomic) NSString *title;
@property (nonatomic) NSString *body;
@property (nonatomic) NSString *source;
@property (nonatomic) NSNumber *duration;
@property (nonatomic) NSString *screen;
@end

@implementation ToastPayload
@end

static ToastPayload *ParsePayload(NSString *line) {
	NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if ([trimmed length] == 0) return nil;

	NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
	id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
	if ([parsed isKindOfClass:NSDictionary.class]) {
		NSDictionary *dict = parsed;
		ToastPayload *p = [ToastPayload new];
		p.title = ConfigStr(dict, @"title", @"");
		p.body = ConfigStr(dict, @"body", @"");
		p.source = ConfigStr(dict, @"source", @"");
		p.screen = ConfigStr(dict, @"screen", @"");
		if ([dict[@"duration"] isKindOfClass:NSNumber.class]) p.duration = dict[@"duration"];
		return p;
	}

	ToastPayload *p = [ToastPayload new];
	p.title = @"";
	p.body = trimmed;
	p.source = @"";
	return p;
}

#pragma mark - Card view

// Decoration only: it must never swallow the click that dismisses the toast.
@interface DecorView : NSView
@end

@implementation DecorView
- (NSView *)hitTest:(NSPoint)point {
	return nil;
}
@end

// Top-down white sheen: on a black desktop a behind-window blur has nothing to
// blur, so the panel has to carry its own light to read as glass.
@interface SheenView : NSView
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

	_gradient = [CAGradientLayer layer];
	// A tight specular edge reads as glass; a broad gradient just greys the whole card.
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

// NSVisualEffectView.maskImage is the supported way to shape vibrancy.
// Layer cornerRadius + masksToBounds on the effect view can swallow the blur.
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

@interface RimView : NSView
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

@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped {
	return YES;
}
@end

@interface ToastCardView : NSView
@property (nonatomic) void (^onDismiss)(void);
@property (nonatomic, readonly) CGFloat cardHeight;
- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config;
@end

@implementation ToastCardView {
	ToastConfig *_config;
	NSVisualEffectView *_fx;
	NSView *_content;
	DecorView *_tint;
	DecorView *_accent;
	DecorView *_border;
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

	// Rail + gap on the left, shared by both accent styles so text always aligns.
	NSString *accentStyle = [config.accentStyle lowercaseString];
	BOOL hasAccent = _showTitle && ![accentStyle isEqualToString:@"none"];
	CGFloat accentSize = [accentStyle isEqualToString:@"bar"] ? config.accentWidth : config.dotSize;
	// The rail sits a bit further in than the text padding: on a tall capsule the
	// surface curves away at the top-left, so a dot at paddingX reads as squeezed.
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
	CGFloat height = config.paddingY * 2 + _titleHeight + gap + _bodyHeight;
	if (_titleHeight == 0 && _bodyHeight == 0) {
		height = config.paddingY * 2 + ceil(titleFont.ascender - titleFont.descender);
	}
	_cardHeight = MAX(height, 36);
	self.frame = NSMakeRect(0, 0, config.width, _cardHeight);

	CGFloat radius = config.cornerRadiusAuto ? _cardHeight / 2.0 : config.cornerRadius;
	NSAutoresizingMaskOptions fill = NSViewWidthSizable | NSViewHeightSizable;

	_content = [[FlippedView alloc] initWithFrame:self.bounds];
	_content.autoresizingMask = fill;

	// 1. Background. macOS 26's NSGlassEffectView is the real Liquid Glass material;
	// NSVisualEffectView is the pre-Tahoe fallback (also used if the class is missing).
	NSString *materialName = [config.material lowercaseString];
	BOOL materialOff = [materialName isEqualToString:@"none"];
	// "classic" / "classic:<name>" forces the pre-Tahoe NSVisualEffectView path.
	BOOL forceClassic = [materialName hasPrefix:@"classic"];
	BOOL glassUsed = NO;

	if (!materialOff && !forceClassic) {
		if (@available(macOS 26.0, *)) {
			if (NSClassFromString(@"NSGlassEffectView")) {
				NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
				glass.cornerRadius = radius;
				glass.tintColor = [config.background colorForDark:dark];
				glass.style = [[config.material lowercaseString] isEqualToString:@"clear"]
				                  ? NSGlassEffectViewStyleClear
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

	// 2. Fallback fill + sheen. The glass material carries its own highlight, so the
	// hand-rolled sheen would only flatten it.
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
		// Only parent the content here. Adding it to self unconditionally would pull it
		// back out of glass.contentView and leave the glass with nothing to render.
		[self addSubview:_content];
	}

	// 3. Accent: a dot on the title line, or a pill running down the text block.
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
				// Centre of the text block: on a tall capsule a dot hugging the title
				// line reads as a stray bullet.
				y = (config.paddingY * 2 + blockHeight - accentSize) / 2.0;
			}
			_accent.frame = NSMakeRect(accentX, y, accentSize, accentSize);
		}
		_accent.layer.cornerRadius = accentSize / 2.0;
		[_content addSubview:_accent];
	}

	// 4. Text.
	_titleField = [NSTextField labelWithString:@""];
	_bodyField = [NSTextField labelWithString:@""];
	[self configureField:_titleField text:titleText maxLines:config.maxTitleLines];
	[self configureField:_bodyField text:bodyText maxLines:config.maxBodyLines];
	_titleField.hidden = !_showTitle;
	_bodyField.hidden = !_showBody;
	[_content addSubview:_titleField];
	[_content addSubview:_bodyField];

	// 5. Hairline border on the very top, so it sits above the material.
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

#pragma mark hover

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

// Tilt toward the cursor with a real perspective transform, plus a slight scale/lift.
// The transform is expressed around the layer's centre so anchorPoint stays AppKit's.
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

#pragma mark - Toast item

// Transparent gutter around the card (room for the 3D tilt). Clicks that land
// there must not be swallowed, otherwise an upper toast eats clicks on the one below.
@interface ToastContainerView : NSView
@end

@implementation ToastContainerView
- (NSView *)hitTest:(NSPoint)point {
	NSView *hit = [super hitTest:point];
	return hit == self ? nil : hit;
}
@end

@interface ToastItem : NSObject
@property (nonatomic) NSPanel *panel;
@property (nonatomic) ToastCardView *card;
@property (nonatomic) NSScreen *screen;
@property (nonatomic) int generation;
@property (nonatomic, copy) dispatch_block_t dismissBlock;
@property (nonatomic) NSTimer *animTimer;
@property (nonatomic) NSInteger animStep, animSteps;
@property (nonatomic) CGFloat animStartAlpha, animTargetAlpha;
@property (nonatomic) NSRect animStartFrame, animTargetFrame;
@property (nonatomic) BOOL animMove;
@property (nonatomic, copy) dispatch_block_t animCompletion;
- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config;
- (void)animateAlpha:(CGFloat)alpha
               frame:(NSRect)frame
                move:(BOOL)move
            duration:(double)duration
          completion:(dispatch_block_t)completion;
- (void)cancelAnimation;
- (void)scheduleWithDuration:(double)duration action:(dispatch_block_t)action;
- (void)cancelTimer;
@end

@implementation ToastItem

- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config {
	self = [super init];
	if (!self) return nil;

	_card = [[ToastCardView alloc] initWithPayload:payload config:config];

	CGFloat gutter = config.hoverEnabled ? MAX(config.hoverMargin, 0) : 0;
	CGFloat panelWidth = config.width + gutter * 2;
	CGFloat panelHeight = _card.cardHeight + gutter * 2;

	NSWindowStyleMask style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
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

	NSString *theme = [config.theme lowercaseString];
	if ([theme isEqualToString:@"dark"]) {
		_panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
	} else if ([theme isEqualToString:@"light"]) {
		_panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantLight];
	} else {
		_panel.appearance = nil; // follow the system
	}
	_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
	                            NSWindowCollectionBehaviorFullScreenAuxiliary |
	                            NSWindowCollectionBehaviorStationary |
	                            NSWindowCollectionBehaviorIgnoresCycle;

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

	// NSTimer (not a dispatch source): invalidating from inside the callback is the
	// supported way to end it, and it avoids the source<->handler retain cycle that
	// kept the panel alive forever.
	self.animTimer = [NSTimer scheduledTimerWithTimeInterval:duration / (double)self.animSteps
	                                                  target:self
	                                                selector:@selector(stepAnimation:)
	                                                userInfo:nil
	                                                 repeats:YES];
}

- (void)stepAnimation:(NSTimer *)timer {
	self.animStep += 1;
	double t = MIN(1.0, (double)self.animStep / (double)self.animSteps);
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

#pragma mark - Toast center

@interface ToastCenter : NSObject
- (void)layoutItems;
@property (nonatomic) ToastConfig *config;
@property (nonatomic) NSMutableArray<ToastItem *> *items;
- (instancetype)initWithConfig:(ToastConfig *)config;
- (void)present:(ToastPayload *)payload;
@end

@implementation ToastCenter

- (instancetype)initWithConfig:(ToastConfig *)config {
	self = [super init];
	if (!self) return nil;
	_config = config;
	_items = [NSMutableArray array];
	return self;
}

// "mouse" | "main" | a screen index like "0"/"1"/"2" | a name substring.
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
	// NSScreen.mainScreen tracks the key window, and an accessory app has none, so it
	// follows the pointer instead. "main" must mean the menu-bar display, deterministically.
	if ([key length] == 0 || [key isEqualToString:@"main"]) return screens.firstObject ?: NSScreen.mainScreen;

	NSInteger index = key.integerValue;
	if (index >= 0 && index < (NSInteger)screens.count &&
	    ([key isEqualToString:[NSString stringWithFormat:@"%ld", (long)index]])) {
		return screens[index];
	}
	for (NSScreen *s in screens) {
		if ([s.localizedName.lowercaseString containsString:key]) return s;
	}
	return screens.firstObject ?: NSScreen.mainScreen;
}

- (void)present:(ToastPayload *)payload {
	ToastItem *item = [[ToastItem alloc] initWithPayload:payload config:self.config];
	item.screen = [self screenFor:(payload.screen.length ? payload.screen : self.config.screen)];

	__weak ToastCenter *weakSelf = self;
	__weak ToastItem *weakItem = item;
	item.card.onDismiss = ^{
		ToastCenter *center = weakSelf;
		ToastItem *target = weakItem;
		if (center && target) [center dismiss:target];
	};
	[self.items insertObject:item atIndex:0];

	int maxVisible = MAX(self.config.maxVisible, 1);
	while ((int)self.items.count > maxVisible) {
		ToastItem *oldest = self.items.lastObject;
		[self.items removeLastObject];
		[oldest cancelTimer];
		[oldest.panel orderOut:nil];
		[oldest.panel close];
	}

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

	// Keep the panel alive until the fade-out finishes: the item itself is already
	// out of the visible list, so it may be deallocated before the completion runs.
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
	// Reflow is instant and never touches alpha: cancelling an in-flight fade-in
	// here is exactly what left freshly queued toasts stuck at alpha 0.
	ToastConfig *c = self.config;
	NSMutableDictionary<NSNumber *, NSNumber *> *cursor = [NSMutableDictionary dictionary];

	for (ToastItem *item in self.items) {
		NSScreen *screen = item.screen ?: NSScreen.screens.firstObject;
		NSNumber *key = @([NSScreen.screens indexOfObject:screen]);
		NSRect visible = screen.visibleFrame;

		CGFloat y = cursor[key] ? cursor[key].doubleValue : NSMaxY(visible) - c.marginTop;
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

#pragma mark - Unix socket

static BOOL FillSockaddr(struct sockaddr_un *addr, NSString *path) {
	memset(addr, 0, sizeof(*addr));
	addr->sun_family = AF_UNIX;
	const char *bytes = path.UTF8String;
	size_t length = strlen(bytes);
	if (length >= sizeof(addr->sun_path)) return NO;
	memcpy(addr->sun_path, bytes, length);
	return YES;
}

static int SendToSocket(NSString *path, NSData *payload) {
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) return -1;

	struct sockaddr_un addr;
	if (!FillSockaddr(&addr, path)) {
		close(fd);
		return ENAMETOOLONG;
	}
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		int err = errno;
		close(fd);
		return err;
	}

	const uint8_t *bytes = payload.bytes;
	NSUInteger total = payload.length;
	NSUInteger offset = 0;
	while (offset < total) {
		ssize_t n = write(fd, bytes + offset, total - offset);
		if (n > 0) {
			offset += (NSUInteger)n;
			continue;
		}
		if (n < 0 && errno == EINTR) continue;
		int err = errno;
		close(fd);
		return err;
	}
	close(fd);
	return 0;
}

static BOOL ServerIsRunning(NSString *path) {
	int err = SendToSocket(path, [NSData data]);
	return err == 0 || err == EPIPE || err == ECONNRESET;
}

@interface ToastServer : NSObject
@property (nonatomic) NSString *path;
@property (nonatomic, copy) void (^onLine)(NSString *line);
- (instancetype)initWithPath:(NSString *)path onLine:(void (^)(NSString *))onLine;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

@implementation ToastServer {
	dispatch_queue_t _queue;
	dispatch_source_t _source;
	int _listenFD;
}

- (instancetype)initWithPath:(NSString *)path onLine:(void (^)(NSString *))onLine {
	self = [super init];
	if (!self) return nil;
	_path = path;
	_onLine = [onLine copy];
	_queue = dispatch_queue_create("toast.socket", DISPATCH_QUEUE_SERIAL);
	_listenFD = -1;
	return self;
}

- (BOOL)start:(NSError **)error {
	NSString *dir = [self.path stringByDeletingLastPathComponent];
	[NSFileManager.defaultManager createDirectoryAtPath:dir
	                        withIntermediateDirectories:YES
	                                         attributes:nil
	                                              error:NULL];
	unlink(self.path.UTF8String);

	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		if (error) *error = [NSError errorWithDomain:@"toast" code:errno userInfo:nil];
		return NO;
	}

	struct sockaddr_un addr;
	if (!FillSockaddr(&addr, self.path)) {
		close(fd);
		if (error) *error = [NSError errorWithDomain:@"toast" code:ENAMETOOLONG userInfo:nil];
		return NO;
	}
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		int err = errno;
		close(fd);
		if (error) *error = [NSError errorWithDomain:@"toast" code:err userInfo:nil];
		return NO;
	}
	chmod(self.path.UTF8String, 0600);
	if (listen(fd, 128) != 0) {
		int err = errno;
		close(fd);
		if (error) *error = [NSError errorWithDomain:@"toast" code:err userInfo:nil];
		return NO;
	}

	_listenFD = fd;
	// Non-blocking accept: the drain loop below must never park the socket queue.
	int flags = fcntl(fd, F_GETFL, 0);
	fcntl(fd, F_SETFL, flags | O_NONBLOCK);

	__weak ToastServer *weakSelf = self;
	_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
	dispatch_source_set_event_handler(_source, ^{
		[weakSelf acceptPending];
	});
	dispatch_resume(_source);
	return YES;
}

- (void)acceptPending {
	while (YES) {
		int clientFD = accept(_listenFD, NULL, NULL);
		if (clientFD < 0) return;
		// macOS hands the O_NONBLOCK flag down to accepted sockets. Clear it so the
		// read loop can block (with SO_RCVTIMEO) instead of mistaking EAGAIN for EOF.
		int flags = fcntl(clientFD, F_GETFL, 0);
		if (flags >= 0) fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			[self readAllFrom:clientFD];
		});
	}
}

- (void)readAllFrom:(int)fd {
	struct timeval timeout = {.tv_sec = 3, .tv_usec = 0};
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

	NSMutableData *data = [NSMutableData data];
	uint8_t buffer[8192];
	while (YES) {
		ssize_t n = read(fd, buffer, sizeof(buffer));
		if (n > 0) {
			[data appendBytes:buffer length:(NSUInteger)n];
			continue;
		}
		if (n < 0 && errno == EINTR) continue;
		break;
	}
	close(fd);

	NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!text) return;
	if (getenv("TOAST_DEBUG")) fprintf(stderr, "toast: <- %s", text.UTF8String);
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		if ([[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] == 0) continue;
		NSString *payload = [line copy];
		void (^handler)(NSString *) = _onLine;
		dispatch_async(dispatch_get_main_queue(), ^{
			handler(payload);
		});
	}
}

- (void)stop {
	if (_source) {
		dispatch_source_cancel(_source);
		_source = nil;
	}
	if (_listenFD >= 0) {
		close(_listenFD);
		_listenFD = -1;
	}
	unlink(self.path.UTF8String);
}

@end

#pragma mark - CLI

static void PrintHelp(void) {
	printf("toast — tiny macOS toast notifier\n\n"
	       "USAGE\n"
	       "  toast serve                       start the resident toast server\n"
	       "  toast send --title T --body B     push a toast\n"
	       "  toast send --json '{...}'         push a raw JSON payload\n"
	       "  echo '{...}' | toast send         read JSON from stdin\n"
	       "  toast preview --title T --body B [--out x.png]\n"
	       "                                    render one card to a PNG\n"
	       "  toast config                      print resolved config\n\n"
	       "OPTIONS\n"
	       "  --config PATH    config file (default ~/.config/pi-toast/config.json)\n"
	       "  --duration SEC   per-toast override\n"
	       "  --source NAME    free-form origin label\n");
}

static NSString *ConfigFlag(NSArray<NSString *> *argv) {
	NSUInteger i = 0;
	while (i < argv.count) {
		NSString *arg = argv[i];
		if ([arg isEqualToString:@"--config"] && i + 1 < argv.count) return argv[i + 1];
		if ([arg hasPrefix:@"--config="]) return [arg substringFromIndex:9];
		i += 1;
	}
	return nil;
}

static NSMutableDictionary<NSString *, NSString *> *ParseFlags(NSArray<NSString *> *argv,
                                                              NSMutableArray<NSString *> *rest) {
	NSSet *valueFlags =
	    [NSSet setWithArray:@[ @"config", @"title", @"body", @"duration", @"source", @"json", @"out", @"screen", @"bg", @"theme" ]];
	NSMutableDictionary<NSString *, NSString *> *flags = [NSMutableDictionary dictionary];
	NSUInteger i = 0;
	while (i < argv.count) {
		NSString *arg = argv[i];
		if ([arg hasPrefix:@"--"]) {
			NSString *name = [arg substringFromIndex:2];
			NSString *value = nil;
			NSRange eq = [name rangeOfString:@"="];
			if (eq.location != NSNotFound) {
				value = [name substringFromIndex:eq.location + 1];
				name = [name substringToIndex:eq.location];
			}
			if ([valueFlags containsObject:name]) {
				if (!value) {
					i += 1;
					value = i < argv.count ? argv[i] : @"";
				}
				flags[name] = value;
			} else {
				flags[name] = value ?: @"true";
			}
		} else {
			[rest addObject:arg];
		}
		i += 1;
	}
	return flags;
}

static int RunClient(NSDictionary<NSString *, NSString *> *flags, ToastConfig *config) {
	NSMutableDictionary *payload = [NSMutableDictionary dictionary];

	NSString *json = flags[@"json"];
	if (json) {
		id parsed = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
		                                            options:0
		                                              error:NULL];
		if (![parsed isKindOfClass:NSDictionary.class]) {
			fprintf(stderr, "toast: --json is not a JSON object\n");
			return 2;
		}
		[payload addEntriesFromDictionary:parsed];
	} else if (!flags[@"title"]) {
		NSData *stdinData = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
		id parsed = [NSJSONSerialization JSONObjectWithData:stdinData options:0 error:NULL];
		if (![parsed isKindOfClass:NSDictionary.class]) {
			fprintf(stderr, "toast: expected JSON on stdin or --title\n");
			return 2;
		}
		[payload addEntriesFromDictionary:parsed];
	} else {
		payload[@"title"] = flags[@"title"];
		payload[@"body"] = flags[@"body"] ?: @"";
	}

	if (flags[@"duration"]) payload[@"duration"] = @(flags[@"duration"].doubleValue);
	if (flags[@"source"]) payload[@"source"] = flags[@"source"];
	if (flags[@"screen"]) payload[@"screen"] = flags[@"screen"];

	NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
	if (!body) return 2;
	NSMutableData *line = [body mutableCopy];
	[line appendBytes:"\n" length:1];

	int err = SendToSocket(config.socketPath, line);
	if (err != 0) {
		NSMutableString *message = [NSMutableString stringWithFormat:@"toast: cannot reach server at %@",
		                                                     config.socketPath];
		if (err > 0) [message appendFormat:@" (%s)", strerror(err)];
		[message appendString:@"\n"];
		fwrite(message.UTF8String, 1, strlen(message.UTF8String), stderr);
		return 1;
	}
	return 0;
}

@interface PreviewBackdrop : NSView
@property (nonatomic) NSColor *fillColor;
@end

@implementation PreviewBackdrop
- (void)drawRect:(NSRect)dirtyRect {
	[self.fillColor setFill];
	NSRectFill(self.bounds);
}
@end

static int RunPreview(NSDictionary<NSString *, NSString *> *flags, ToastConfig *config) {
	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

	ToastPayload *payload = [ToastPayload new];
	payload.title = flags[@"title"] ?: @"";
	payload.body = flags[@"body"] ?: @"";

	// Allow previewing a candidate config file without touching the live one.
	if (flags[@"config"]) config = [ToastConfig loadFromPath:flags[@"config"]];
	if (flags[@"theme"]) config.theme = flags[@"theme"];

	// The offscreen render cannot show vibrancy, it only paints the material's flat
	// fallback colour, so preview always renders the no-material variant.
	NSString *material = config.material;
	config.material = @"none";

	ToastCardView *card = [[ToastCardView alloc] initWithPayload:payload config:config];
	(void)material;

	// Cache display keeps alpha, which most viewers flatten onto white and would
	// misrepresent a dark panel. Composite onto an explicit backdrop (--bg) instead.
	NSSize size = card.bounds.size;
	PreviewBackdrop *canvas = [[PreviewBackdrop alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
	canvas.fillColor = HexColor(flags[@"bg"] ?: @"#0A0A0A", NSColor.blackColor);
	[canvas addSubview:card];

	NSBitmapImageRep *rep = [canvas bitmapImageRepForCachingDisplayInRect:canvas.bounds];
	[canvas cacheDisplayInRect:canvas.bounds toBitmapImageRep:rep];
	NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];

	NSString *out = ExpandTilde(flags[@"out"] ?: @"/tmp/toast-preview.png");
	if (![png writeToFile:out atomically:YES]) {
		fprintf(stderr, "toast: cannot write %s\n", out.UTF8String);
		return 1;
	}
	printf("%s\n", out.UTF8String);
	return 0;
}

static int RunServer(ToastConfig *config) {
	if (ServerIsRunning(config.socketPath)) {
		printf("toast: server already running at %s\n", config.socketPath.UTF8String);
		return 0;
	}

	[NSApplication sharedApplication];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

	ToastCenter *center = [[ToastCenter alloc] initWithConfig:config];
	ToastServer *server = [[ToastServer alloc] initWithPath:config.socketPath
	                                                 onLine:^(NSString *line) {
		                                                 ToastPayload *payload = ParsePayload(line);
		                                                 if (payload) [center present:payload];
	                                                 }];

	NSError *error = nil;
	if (![server start:&error]) {
		fprintf(stderr, "toast: cannot start server on %s: %s\n", config.socketPath.UTF8String,
		        strerror((int)error.code));
		return 1;
	}

	fprintf(stderr, "toast: listening on %s\n", config.socketPath.UTF8String);

	signal(SIGPIPE, SIG_IGN);
	for (int sig = 0; sig < 3; sig++) {
		int signals[3] = {SIGINT, SIGTERM, SIGHUP};
		signal(signals[sig], SIG_IGN);
		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signals[sig], 0,
		                                                  dispatch_get_main_queue());
		dispatch_source_set_event_handler(source, ^{
			[server stop];
			exit(0);
		});
		dispatch_resume(source);
	}

	[NSApp run];
	[server stop];
	return 0;
}

int main(int argc, const char *argv[]) {
	@autoreleasepool {
		NSMutableArray<NSString *> *args = [NSMutableArray array];
		for (int i = 1; i < argc; i++) {
			[args addObject:[NSString stringWithUTF8String:argv[i]]];
		}

		NSMutableArray<NSString *> *rest = [NSMutableArray array];
		NSDictionary<NSString *, NSString *> *flags = ParseFlags(args, rest);
		NSString *command = rest.count > 0 ? rest[0] : @"serve";
		ToastConfig *config = [ToastConfig loadFromPath:ConfigFlag(args)];

		if ([command isEqualToString:@"help"] || [flags[@"help"] boolValue]) {
			PrintHelp();
			return 0;
		}
		if ([command isEqualToString:@"version"] || [flags[@"version"] boolValue]) {
			printf("toast 0.1.0\n");
			return 0;
		}
		if ([command isEqualToString:@"config"]) {
			printf("config: %s%s\n", config.configPath.UTF8String,
			       [config hasConfigFile] ? "" : " (missing, using defaults)");
			printf("socket: %s%s\n", config.socketPath.UTF8String,
			       ServerIsRunning(config.socketPath) ? " (server running)" : "");
			printf("duration: %.1fs  width: %.0f  maxVisible: %d\n", config.duration, config.width,
			       config.maxVisible);
			printf("level: %s  screen: %s\n", config.level.UTF8String, config.screen.UTF8String);
			printf("showTitle: %d  showBody: %d\n", config.showTitle, config.showBody);
			return 0;
		}
		if ([command isEqualToString:@"send"]) {
			return RunClient(flags, config);
		}
		if ([command isEqualToString:@"preview"]) {
			return RunPreview(flags, config);
		}
		return RunServer(config);
	}
}
