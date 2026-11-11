#import "Config.h"
#import <dispatch/dispatch.h>

#pragma mark - 基础解析

NSString *ExpandTilde(NSString *path) {
	// 配置里允许写 ~ 开头的路径，换台机器不用改绝对路径
	if (![path hasPrefix:@"~"]) return path;
	return [NSHomeDirectory() stringByAppendingPathComponent:[path substringFromIndex:1]];
}

// 支持 RRGGBB / RRGGBBAA，非法值退回 fallback
NSColor *HexColor(NSString *hex, NSColor *fallback) {
	if (![hex isKindOfClass:NSString.class]) return fallback;
	NSString *s = [[hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
		stringByReplacingOccurrencesOfString:@"#" withString:@""];
	if (s.length != 6 && s.length != 8) return fallback;
	unsigned long long v = 0;
	NSScanner *scanner = [NSScanner scannerWithString:s];
	// isAtEnd 一起查，防止 "#FFF123xyz" 这种前半截合法的值蒙混过关
	if (![scanner scanHexLongLong:&v] || !scanner.isAtEnd) return fallback;
	BOOL hasAlpha = s.length == 8;
	double r = (double)((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255.0;
	double g = (double)((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255.0;
	double b = (double)((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255.0;
	double a = hasAlpha ? (double)(v & 0xFF) / 255.0 : 1.0;
	return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

NSFontWeight ParseWeight(NSString *name) {
	// 认不出的名字按 regular：字重写错不该让卡片弹不出来
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

NSDictionary *ConfigObject(NSDictionary *dict, NSString *key) {
	// 子对象缺失或写成别的类型时给个空字典，下一层照常取默认值
	id v = dict[key];
	return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

double ConfigNum(NSDictionary *dict, NSString *key, double fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}

int ConfigInt(NSDictionary *dict, NSString *key, int fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v intValue] : fallback;
}

BOOL ConfigBool(NSDictionary *dict, NSString *key, BOOL fallback) {
	id v = dict[key];
	return [v isKindOfClass:NSNumber.class] ? [v boolValue] : fallback;
}

NSString *ConfigStr(NSDictionary *dict, NSString *key, NSString *fallback) {
	id v = dict[key];
	if ([v isKindOfClass:NSString.class] && [v length] > 0) return v;
	return fallback;
}

#pragma mark - ThemeColor

@implementation ThemeColor

- (NSColor *)colorForDark:(BOOL)dark {
	return dark ? (self.dark ?: self.light) : (self.light ?: self.dark);
}

- (CGColorRef)cgColorForDark:(BOOL)dark {
	return [self colorForDark:dark].CGColor;
}

@end

static ThemeColor *ConfigColor(NSDictionary *dict, NSString *key, NSString *darkHex, NSString *lightHex) {
	// 三种写法：单个 hex（明暗共用）、{"light":..,"dark":..}、不写（用内置默认）
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

#pragma mark - 配置位置

static NSString *const kUserConfigPath = @"~/Library/Application Support/Toast/config.json";
static NSString *const kLegacyConfigPath = @"~/.config/pi-toast/config.json";
static NSString *const kSystemConfigPath = @"/Library/Application Support/Toast/config.json";

// 优先级从高到低，第一个存在的文件生效
// 旧位置排第二：已经装过的人和脚本都还在用它，不强制搬家
static NSArray<NSString *> *ConfigSearchPaths(void) {
	static NSArray<NSString *> *paths;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		paths = @[ ExpandTilde(kUserConfigPath), ExpandTilde(kLegacyConfigPath), kSystemConfigPath ];
	});
	return paths;
}

#pragma mark - ToastConfig

@interface ToastConfig ()
@property (nonatomic) NSString *configPath;
@property (nonatomic) BOOL configLoaded;
@property (nonatomic) NSArray<NSString *> *searchedPaths;
@end

@implementation ToastConfig

+ (instancetype)load {
	// 环境变量比文件优先，方便临时换一份配置试效果
	NSString *env = NSProcessInfo.processInfo.environment[@"PI_TOAST_CONFIG"];
	if (env.length > 0) return [self loadFromPath:env];

	NSMutableArray<NSString *> *searched = [NSMutableArray array];
	NSArray<NSString *> *chain = ConfigSearchPaths();
	for (NSString *candidate in chain) {
		// 每试一个都记下来，全空时 toast config 要把这条链完整打出来
		[searched addObject:candidate];
		if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) continue;
		ToastConfig *config = [self configFromPath:candidate];
		config.searchedPaths = searched;
		return config;
	}

	// 一个都没命中：以首选位置为名义路径，值全部走内置默认
	ToastConfig *config = [self configFromPath:chain.firstObject];
	config.searchedPaths = searched;
	return config;
}

+ (instancetype)loadFromPath:(NSString *)path {
	NSString *expanded = ExpandTilde(path);
	ToastConfig *config = [self configFromPath:expanded];
	config.searchedPaths = @[ expanded ];
	return config;
}

+ (instancetype)configFromPath:(NSString *)path {
	NSDictionary *root = @{};
	NSData *data = [NSData dataWithContentsOfFile:path];
	if (data.length > 0) {
		id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		if ([parsed isKindOfClass:NSDictionary.class]) {
			root = parsed;
		} else {
			// 文件在但坏了：告警一次再拿默认值顶上，总比一声不响地弹出错误样式好
			fprintf(stderr, "toast: %s is not a JSON object, using defaults\n", path.UTF8String);
		}
	}

	ToastConfig *c = [ToastConfig new];
	c.configPath = path;
	c.configLoaded = data.length > 0;
	c.socketPath = ExpandTilde(ConfigStr(root, @"socket", @"~/.pi-toast/toast.sock"));

	NSDictionary *a = ConfigObject(root, @"appearance");
	// 尺寸与四周留白
	c.width = ConfigNum(a, @"width", 340);
	c.marginTop = ConfigNum(a, @"marginTop", 14);
	c.marginRight = ConfigNum(a, @"marginRight", 14);
	c.marginLeft = ConfigNum(a, @"marginLeft", 14);
	c.spacing = ConfigNum(a, @"spacing", 8);
	// "capsule" 表示圆角始终等于卡片高度的一半，换行变高时比例不变
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
	// 颜色在这里落地：dark 是深色模式下的值，light 是浅色模式下的值
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
	// 悬停留白要算进窗口尺寸，否则倾斜时四角会被裁掉
	NSDictionary *h = ConfigObject(a, @"hover");
	c.hoverEnabled = ConfigBool(h, @"enabled", YES);
	c.hoverTilt = ConfigNum(h, @"tilt", 9);
	c.hoverScale = ConfigNum(h, @"scale", 1.03);
	c.hoverLift = ConfigNum(h, @"lift", 2);
	c.hoverDuration = ConfigNum(h, @"duration", 0.12);

	NSDictionary *b = ConfigObject(root, @"behavior");
	// duration 是每条停留秒数，payload 里带的会覆盖它
	c.duration = ConfigNum(b, @"duration", 10);
	c.fadeIn = ConfigNum(b, @"fadeIn", 0.16);
	c.fadeOut = ConfigNum(b, @"fadeOut", 0.22);
	c.maxVisible = ConfigInt(b, @"maxVisible", 4);
	c.clickToDismiss = ConfigBool(b, @"clickToDismiss", YES);
	c.level = ConfigStr(b, @"level", @"floating");
	c.screen = ConfigStr(b, @"screen", @"main");
	c.align = ConfigStr(b, @"align", @"center");

	NSDictionary *ct = ConfigObject(root, @"content");
	c.showTitle = ConfigBool(ct, @"showTitle", YES);
	c.showBody = ConfigBool(ct, @"showBody", YES);

	return c;
}

- (BOOL)isDarkMode {
	// theme 写了 dark/light 就照办，写 system 或不认识时跟随系统
	NSString *theme = [self.theme lowercaseString];
	if ([theme isEqualToString:@"dark"]) return YES;
	if ([theme isEqualToString:@"light"]) return NO;
	NSAppearanceName name = [NSApp.effectiveAppearance
	    bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
	return [name isEqualToString:NSAppearanceNameDarkAqua];
}

@end
