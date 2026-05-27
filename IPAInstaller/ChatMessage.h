#import <Foundation/Foundation.h>

// One message in a conversation. role = "system"/"user"/"assistant"/"tool".
@interface ChatMessage : NSObject
@property (nonatomic, copy) NSString *role;
@property (nonatomic, copy) NSString *content;        // may be nil if assistant did tool call only
@property (nonatomic, copy) NSArray *toolCalls;       // for assistant: array of tool_call dicts
@property (nonatomic, copy) NSString *toolCallId;     // for tool role: which call this is responding to
@property (nonatomic, copy) NSString *name;           // for tool role: function name
// For UI display
@property (nonatomic, strong) NSArray *attachedApps;  // optional list of app dicts (catalog results) to show as cards
- (NSDictionary *)toJSON;
+ (instancetype)fromJSON:(NSDictionary *)json;
+ (instancetype)user:(NSString *)text;
+ (instancetype)assistant:(NSString *)text;
+ (instancetype)system:(NSString *)text;
+ (instancetype)tool:(NSString *)content callId:(NSString *)callId name:(NSString *)name;
@end
