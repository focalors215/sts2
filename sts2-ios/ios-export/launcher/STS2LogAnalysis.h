#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 日志 AI 分析，对齐 Android llm/ + loganalysis/：自定义 OpenAI 兼容 Chat Completions + 两个只读工具
/// （read_lines / search_logs），只把模型按需读取的日志片段发出去；每个问题最多 24 轮、每轮最多 8 个工具。
/// API key 只存本机钥匙串。只依赖 Foundation，可宿主测试。

@interface STS2LlmConfig : NSObject
@property(nonatomic, copy) NSString *baseURL, *apiKey, *model, *reasoningEffort;
/// Base URL 可填 /v1 基址或完整 /chat/completions；站点根地址补 /v1。非法返回 nil 并给出中文原因。
- (nullable NSURL *)endpoint:(NSString *_Nullable *_Nullable)problem;
- (nullable NSString *)validationProblem;
@end

typedef BOOL (^STS2Cancelled)(void);

@interface STS2LogTools : NSObject
/// 1–3 个文件；file_id 为 log_1…，不是路径。
- (nullable instancetype)initWithFiles:(NSArray<NSURL *> *)files error:(NSError **)error;
- (NSArray *)metadata;
- (NSString *)systemPrompt;
- (NSArray *)definitions;
- (NSDictionary *)execute:(NSString *)name arguments:(NSDictionary *)arguments;
- (NSString *)summaryForTool:(NSString *)name result:(NSDictionary *)result;
@end

/// 传输层：同步返回 assistant message 字典，失败给出可展示的中文错误。
typedef NSDictionary *_Nullable (^STS2ChatTransport)(NSArray *messages, NSArray *tools, STS2Cancelled cancelled, NSError **error);

@interface STS2ChatSession : NSObject
+ (NSInteger)maxRounds;
- (instancetype)initWithTransport:(STS2ChatTransport)transport tools:(STS2LogTools *)tools;
/// 在后台线程调用。返回最终分析文本；失败时回滚本次问题的消息。
- (nullable NSString *)ask:(NSString *)question cancelled:(STS2Cancelled)cancelled
                  progress:(void (^)(NSString *status))progress budgetReached:(BOOL *_Nullable)budgetReached error:(NSError **)error;
@end

/// NSURLSession 实现：不跟随重定向、响应上限 1 MiB、不回显服务错误正文。
STS2ChatTransport STS2OpenAiTransport(STS2LlmConfig *config);

NS_ASSUME_NONNULL_END
