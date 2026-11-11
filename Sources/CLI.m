#import "CLI.h"
#import "Config.h"
#import "CardView.h"
#import "Payload.h"
#import "Socket.h"
#import "ToastCenter.h"
#include <signal.h>
#include <string.h>
#include <unistd.h>

#pragma mark - 参数

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
	       "  --config PATH    config file, skips the default search\n"
	       "  --duration SEC   per-toast override\n"
	       "  --source NAME    free-form origin label\n\n"
	       "CONFIG SEARCH (first hit wins)\n"
	       "  1  ~/Library/Application Support/Toast/config.json\n"
	       "  2  ~/.config/pi-toast/config.json\n"
	       "  3  /Library/Application Support/Toast/config.json\n"
	       "  --config and $PI_TOAST_CONFIG win over all three\n");
}

static NSMutableDictionary<NSString *, NSString *> *ParseFlags(NSArray<NSString *> *argv,
                                                              NSMutableArray<NSString *> *rest) {
	// 带值的 flag 列在这里，其余 --x 当开关；--key value 与 --key=value 都认
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
				// 值可能被写成 --title= 后面的空串，也可能根本不跟值
				if (!value) {
					i += 1;
					value = i < argv.count ? argv[i] : @"";
				}
				flags[name] = value;
			} else {
				flags[name] = value ?: @"true";
			}
		} else {
			// 第一个非 flag 参数就是子命令
			[rest addObject:arg];
		}
		i += 1;
	}
	return flags;
}

#pragma mark - send

static int RunClient(NSDictionary<NSString *, NSString *> *flags, ToastConfig *config) {
	NSMutableDictionary *payload = [NSMutableDictionary dictionary];

	NSString *json = flags[@"json"];
	// 三种来源：--json 原文，其次 stdin，最后才是 --title/--body 拼一条
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
		// 连不上多半是 server 没跑，把原因写清楚而不是只给个退出码
		NSMutableString *message = [NSMutableString stringWithFormat:@"toast: cannot reach server at %@",
		                                                     config.socketPath];
		if (err > 0) [message appendFormat:@" (%s)", strerror(err)];
		[message appendString:@"\n"];
		fwrite(message.UTF8String, 1, strlen(message.UTF8String), stderr);
		return 1;
	}
	return 0;
}

#pragma mark - preview

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
	if (flags[@"theme"]) config.theme = flags[@"theme"];

	// 离屏渲染画不出毛玻璃，只能画成一块灰，所以强制走无材质路径
	config.material = @"none";

	ToastCardView *card = [[ToastCardView alloc] initWithPayload:payload config:config];

	// cacheDisplay 会保留 alpha，多数看图工具把它压到白底上，深色卡片就失真了，
	// 所以先合成到显式底色再导出
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

#pragma mark - serve

static int RunServer(ToastConfig *config) {
	// 顺手拿它当心跳：已经在跑就别再起一个来抢 socket
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

	// 信号自己接手，所以要先忽略默认行为；SIGPIPE 忽略是因为客户端提前断开不该杀掉 server
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

#pragma mark - 分发

static void PrintConfig(ToastConfig *config) {
	// 先把命中的文件说清楚，排查问题时第一时间要用
	printf("config: %s%s\n", config.configPath.UTF8String,
	       config.configLoaded ? "" : " (missing, using defaults)");
	if (!config.configLoaded) {
		for (NSString *path in config.searchedPaths) printf("  tried: %s\n", path.UTF8String);
	}
	printf("socket: %s%s\n", config.socketPath.UTF8String,
	       ServerIsRunning(config.socketPath) ? " (server running)" : "");
	printf("duration: %.1fs  width: %.0f  maxVisible: %d\n", config.duration, config.width, config.maxVisible);
	printf("level: %s  screen: %s\n", config.level.UTF8String, config.screen.UTF8String);
	printf("showTitle: %d  showBody: %d\n", config.showTitle, config.showBody);
}

int RunCLI(int argc, const char *argv[]) {
	NSMutableArray<NSString *> *args = [NSMutableArray array];
	for (int i = 1; i < argc; i++) {
		[args addObject:[NSString stringWithUTF8String:argv[i]]];
	}

	NSMutableArray<NSString *> *rest = [NSMutableArray array];
	NSDictionary<NSString *, NSString *> *flags = ParseFlags(args, rest);
	NSString *command = rest.count > 0 ? rest[0] : @"serve";

	if ([command isEqualToString:@"help"] || [flags[@"help"] boolValue]) {
		PrintHelp();
		return 0;
	}
	if ([command isEqualToString:@"version"] || [flags[@"version"] boolValue]) {
		printf("toast 0.1.0\n");
		return 0;
	}

	ToastConfig *config = flags[@"config"] ? [ToastConfig loadFromPath:flags[@"config"]] : [ToastConfig load];

	if ([command isEqualToString:@"config"]) {
		PrintConfig(config);
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
