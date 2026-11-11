#import "Socket.h"
#import <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static BOOL FillSockaddr(struct sockaddr_un *addr, NSString *path) {
	// sun_path 是定长数组，超长的路径只能报错，没有截断的余地
	memset(addr, 0, sizeof(*addr));
	addr->sun_family = AF_UNIX;
	const char *bytes = path.UTF8String;
	size_t length = strlen(bytes);
	if (length >= sizeof(addr->sun_path)) return NO;
	memcpy(addr->sun_path, bytes, length);
	return YES;
}

int SendToSocket(NSString *path, NSData *payload) {
	// 一次连接写完就关：协议只有「一行 JSON」，不需要长连接和握手
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
	// write 可能只写一半，被信号打断还要重试
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

BOOL ServerIsRunning(NSString *path) {
	// 发空数据：能连上就是活着，对端已关闭也算
	int err = SendToSocket(path, [NSData data]);
	return err == 0 || err == EPIPE || err == ECONNRESET;
}

@interface ToastServer ()
@property (nonatomic) NSString *path;
@property (nonatomic, copy) void (^onLine)(NSString *line);
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
	// 上次异常退出会留下 socket 文件，不 unlink 会 bind 失败
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
	// 128 是排队上限，正常只有单个 CLI 连进来，用不到这么多
	if (listen(fd, 128) != 0) {
		int err = errno;
		close(fd);
		if (error) *error = [NSError errorWithDomain:@"toast" code:err userInfo:nil];
		return NO;
	}

	_listenFD = fd;
	// 监听 fd 必须非阻塞，否则 drain 循环会永久卡住 socket 队列
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
		// macOS 会把监听 fd 的 O_NONBLOCK 继承给 accept 出来的连接，必须清掉，
		// 否则读循环会把 EAGAIN 当成 EOF 立刻断开
		int flags = fcntl(clientFD, F_GETFL, 0);
		if (flags >= 0) fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			[self readAllFrom:clientFD];
		});
	}
}

- (void)readAllFrom:(int)fd {
	// 3 秒收不到数据就放弃：客户端连上不写不能把线程占死
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
	// 一次读到的是多个连接的拼接结果：可能半行、也可能好几行，统按换行切
	for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
		if ([[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] == 0) continue;
		NSString *payload = [line copy];
		// 解析和上屏都要在主线程碰 AppKit，这里只把行转发过去
		void (^handler)(NSString *) = _onLine;
		dispatch_async(dispatch_get_main_queue(), ^{
			handler(payload);
		});
	}
}

- (void)stop {
	// 退出前把 socket 文件删掉，否则下次启动会 bind 到别人的遗留文件上
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
