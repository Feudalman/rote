// 卡片绘制
#pragma once
#import <Cocoa/Cocoa.h>
#import "Config.h"
#import "Payload.h"

@interface ToastCardView : NSView
@property (nonatomic) void (^onDismiss)(void);
@property (nonatomic, readonly) CGFloat cardHeight;
- (instancetype)initWithPayload:(ToastPayload *)payload config:(ToastConfig *)config;
@end
