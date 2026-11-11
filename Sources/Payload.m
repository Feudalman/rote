#import "Payload.h"
#import "Config.h"

@implementation ToastPayload
@end

ToastPayload *ParsePayload(NSString *line) {
	NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (trimmed.length == 0) return nil;

	// 先当 JSON 解，解不出就当纯文本，让 echo 一句话也能直接弹
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
