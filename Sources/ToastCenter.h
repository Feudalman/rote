// 通知队列：分配屏幕、堆叠布局、生命周期
#pragma once
#import <Cocoa/Cocoa.h>
#import "Config.h"
#import "Payload.h"

@interface ToastCenter : NSObject
- (instancetype)initWithConfig:(ToastConfig *)config;
- (void)present:(ToastPayload *)payload;
@end
