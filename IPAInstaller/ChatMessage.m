#import "ChatMessage.h"

@implementation ChatMessage

+ (instancetype)user:(NSString *)text {
    ChatMessage *m = [[ChatMessage alloc] init];
    m.role = @"user"; m.content = text;
    return m;
}

+ (instancetype)assistant:(NSString *)text {
    ChatMessage *m = [[ChatMessage alloc] init];
    m.role = @"assistant"; m.content = text;
    return m;
}

+ (instancetype)system:(NSString *)text {
    ChatMessage *m = [[ChatMessage alloc] init];
    m.role = @"system"; m.content = text;
    return m;
}

+ (instancetype)tool:(NSString *)content callId:(NSString *)callId name:(NSString *)name {
    ChatMessage *m = [[ChatMessage alloc] init];
    m.role = @"tool"; m.content = content; m.toolCallId = callId; m.name = name;
    return m;
}

+ (instancetype)fromJSON:(NSDictionary *)json {
    ChatMessage *m = [[ChatMessage alloc] init];
    m.role = json[@"role"];
    id c = json[@"content"];
    m.content = [c isKindOfClass:[NSString class]] ? c : nil;
    m.toolCalls = json[@"tool_calls"];
    m.toolCallId = json[@"tool_call_id"];
    m.name = json[@"name"];
    return m;
}

- (NSDictionary *)toJSON {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"role"] = self.role ?: @"user";
    if (self.content) d[@"content"] = self.content;
    else if ([self.role isEqualToString:@"assistant"] && self.toolCalls.count > 0) {
        // assistant message with only tool calls — content can be null in OpenAI/Groq
        // We omit "content" instead of sending nil to keep JSON clean
    }
    if (self.toolCalls.count) d[@"tool_calls"] = self.toolCalls;
    if (self.toolCallId) d[@"tool_call_id"] = self.toolCallId;
    if (self.name) d[@"name"] = self.name;
    return d;
}

@end
