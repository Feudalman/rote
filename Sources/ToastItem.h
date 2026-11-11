// 单条通知：面板、动画、停留计时
#pragma once
#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import "CardView.h"
#import "Config.h"
#import "Payload.h"

@interface ToastItem : NSObject
@property (nonatomic) NSPanel *panel;
@property (nonatomic) ToastCardView *card;
@property (nonatomic) NSScreen *screen;
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
