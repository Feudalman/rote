// 配置模型与加载
#pragma once
#import <Cocoa/Cocoa.h>

// 随深浅色切换的颜色，配置里可以写单个 hex，也可以写 {"light":"#..","dark":"#.."}
@interface ThemeColor : NSObject
@property (nonatomic) NSColor *light;
@property (nonatomic) NSColor *dark;
- (NSColor *)colorForDark:(BOOL)dark;
- (CGColorRef)cgColorForDark:(BOOL)dark;
@end

@interface ToastConfig : NSObject

// 命中的文件；一个都不存在时是首选位置
@property (nonatomic, readonly) NSString *configPath;
@property (nonatomic, readonly) BOOL configLoaded;
@property (nonatomic, readonly) NSArray<NSString *> *searchedPaths;

@property (nonatomic) NSString *socketPath;

// 尺寸与圆角
@property (nonatomic) CGFloat width, marginTop, marginRight, marginLeft, spacing, cornerRadius;
@property (nonatomic) BOOL cornerRadiusAuto;
@property (nonatomic) CGFloat paddingX, paddingY, accentWidth, borderWidth;

// 字体与行距
@property (nonatomic) CGFloat titleSize, bodySize, titleBodyGap, lineSpacing;

// 左侧强调件：圆点或竖条，距边距多少、垂直对齐到哪
@property (nonatomic) CGFloat dotSize, dotGap, accentInset;
@property (nonatomic) NSString *accentAlign;

// 外观模式：材质、明暗、行数上限、颜色、字重、阴影与高光
@property (nonatomic) NSString *accentStyle, *material, *theme;
@property (nonatomic) int maxTitleLines, maxBodyLines;
@property (nonatomic) ThemeColor *accentColor, *background, *borderColor, *titleColor, *bodyColor;
@property (nonatomic) NSFontWeight titleWeight, bodyWeight;
@property (nonatomic) BOOL shadow;
@property (nonatomic) CGFloat sheen;

// 悬停时的 3D 倾斜，默认关
@property (nonatomic) BOOL hoverEnabled;
@property (nonatomic) CGFloat hoverTilt, hoverScale, hoverLift, hoverDuration, hoverMargin;

// 行为：停留时长、淡入淡出、并发上限、窗口层级、落在哪块屏
@property (nonatomic) double duration, fadeIn, fadeOut;
@property (nonatomic) int maxVisible;
@property (nonatomic) BOOL clickToDismiss;
@property (nonatomic) NSString *level, *screen, *align;

// 内容开关，关掉后对应字段整块不占高度
@property (nonatomic) BOOL showTitle, showBody;

// 走搜索链加载，全都不存在时返回全默认值
+ (instancetype)load;
// 指定文件，不做任何回退
+ (instancetype)loadFromPath:(NSString *)path;
- (BOOL)isDarkMode;

@end

// 配置值解析，类型不符一律退回默认值
NSString *ExpandTilde(NSString *path);
NSColor *HexColor(NSString *hex, NSColor *fallback);
NSFontWeight ParseWeight(NSString *name);
NSDictionary *ConfigObject(NSDictionary *dict, NSString *key);
double ConfigNum(NSDictionary *dict, NSString *key, double fallback);
int ConfigInt(NSDictionary *dict, NSString *key, int fallback);
BOOL ConfigBool(NSDictionary *dict, NSString *key, BOOL fallback);
NSString *ConfigStr(NSDictionary *dict, NSString *key, NSString *fallback);
