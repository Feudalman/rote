// unix socket 收发
#pragma once
#import <Foundation/Foundation.h>

// 返回 errno，0 表示写成功
int SendToSocket(NSString *path, NSData *payload);

// 能连上就算在跑
BOOL ServerIsRunning(NSString *path);

// 每读到一行文本回调一次
@interface ToastServer : NSObject
- (instancetype)initWithPath:(NSString *)path onLine:(void (^)(NSString *line))onLine;
- (BOOL)start:(NSError **)error;
- (void)stop;
@end
