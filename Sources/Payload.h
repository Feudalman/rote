// socket 上传来的单条通知
#pragma once
#import <Foundation/Foundation.h>

@interface ToastPayload : NSObject
@property (nonatomic) NSString *title;
@property (nonatomic) NSString *body;
@property (nonatomic) NSString *source;
@property (nonatomic) NSNumber *duration;
@property (nonatomic) NSString *screen;
@end

// 一行文本 → payload，非 JSON 的行整行当正文
ToastPayload *ParsePayload(NSString *line);
