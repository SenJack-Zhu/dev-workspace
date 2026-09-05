# MoRead AI 模块 API 参考手册

> 扫描目录：`app/src/main/java/com/mozhi/reader/ai/`
> 共 13 个子目录，约 65 个 Kotlin 文件
> 生成时间：2026-09-05

---

## 目录导航

| 子目录 | 功能领域 | 文件数 | 优先级 |
|--------|---------|--------|--------|
| [ai/listen/](#ailisten-听书引擎) | 听书引擎 | 3 | ★★★ |
| [ai/audiobook/](#aiaudiobook-有声书制作) | 有声书制作 | 9 | ★★★ |
| [ai/agent/](#aiagent-ai-agent-工具) | AI Agent 工具 | 7 | ★★☆ |
| [ai/chat/](#aichat-聊天相关) | 聊天相关 | 3 | ★★☆ |
| [ai/client/](#aiclient-ai-客户端api) | AI 客户端/API | 17 | ★★☆ |
| [ai/persona/](#aipersona-角色人设) | 角色人设 | 3 | ★★☆ |
| [ai/memory/](#aimemory-记忆系统) | 记忆系统 | 7 | ★★☆ |
| [ai/companion/](#aicompanion-陪伴功能) | 陪伴功能 | 1 | ★☆☆ |
| [ai/embedding/](#aiembedding-向量嵌入) | 向量嵌入 | 4 | ★☆☆ |
| [ai/media/](#aimedia-媒体生成) | 媒体生成 | 4 | ★☆☆ |
| [ai/prompt/](#aiprompt-提示词) | 提示词 | 3 | ★☆☆ |
| [ai/provider/](#aiprovider-提供商管理) | 提供商管理 | 4 | ★☆☆ |
| [ai/search/](#aisearch-网页搜索) | 网页搜索 | 2 | ★☆☆ |

---

## ai/listen/ — 听书引擎

### ListenEngine.kt

**文件路径：** `ai/listen/ListenEngine.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ListenPlaybackMode` (enum) | public | 听书播放模式枚举：STANDARD（普通 TTS）/ PRODUCED（多角色成品） |
| `ListenState` (data class) | public | 听书会话对外快照，包含书籍、章节、句子、播放状态等信息 |
| `ListenEngine` (class) | public `@Singleton` | 连续听书核心引擎：逐句朗读、自动翻章、AI/系统 TTS 切换、预取、睡眠定时 |
| `Utterance` (data class) | private | 单句朗读单元，含文本、引擎模式、音色、情绪、音频路径等 |
| `PendingSeek` (data class) | private | 待执行的跳转位置 |
| `ChapterPlaybackPlan` (data class) | private | 单章播放计划，含 utterance 列表与是否脚本化 |
| `SpeakResult` (sealed interface) | private | 单句朗读结果：DONE / INTERRUPTED / Error |

**ListenEngine 关键 public 方法：**

```kotlin
// 构造
@Inject constructor(
    context: Context,
    libraryRepository: LibraryRepository,
    readerSettingsRepository: ReaderSettingsRepository,
    ttsSettingsStore: TtsSettingsStore,
    systemTtsSpeaker: SystemTtsSpeaker,
    mediaService: AiMediaGenerationService,
    audiobookRepository: AudiobookRepository,
    hookRegistry: HookRegistry
)

// 播放控制
fun start(bookId: Long, chapterIndex: Int, charOffset: Int,
          playbackMode: ListenPlaybackMode = STANDARD)
fun pause()
fun resume()
fun toggle()
fun stop()

// 进度与跳转
fun seekTo(chapterIndex: Int, charOffset: Int)
fun seekToChapterFraction(fraction: Float)
fun nextSentence()
fun prevSentence()
fun nextChapter()
fun prevChapter()

// 睡眠定时
fun setSleepTimer(plan: SleepTimerPlan?)

// 状态观察
val state: StateFlow<ListenState?>
val sleepTimer: StateFlow<SleepTimerState?>
val isActive: Boolean
fun isListening(bookId: Long): Boolean
fun isListening(bookId: Long, playbackMode: ListenPlaybackMode): Boolean
```

---

### ListenService.kt

**文件路径：** `ai/listen/ListenService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ListenService` (class) | public `@AndroidEntryPoint` | 前台媒体服务：维持后台朗读，向锁屏/耳机/车机/手表发布播放控制（MediaSession） |

**ListenService 关键方法：**

```kotlin
// 生命周期
override fun onCreate()
override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int
override fun onDestroy()

// 静态入口
companion object {
    fun start(context: Context, bookId: Long, chapterIndex: Int,
              charOffset: Int, playbackMode: ListenPlaybackMode)
    fun stop(context: Context)
}
```

---

### ListenAudioFocusPolicy.kt

**文件路径：** `ai/listen/ListenAudioFocusPolicy.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ListenAudioFocusAction` (enum) | internal | 音频焦点变更后的动作枚举：NONE / PAUSE / PAUSE_AND_RESUME / RESUME |
| `decideListenAudioFocusAction()` (fun) | internal | 根据焦点变更类型、当前播放状态与恢复挂起状态，决定下一步动作 |

---

## ai/audiobook/ — 有声书制作

### AudiobookProducer.kt

**文件路径：** `ai/audiobook/AudiobookProducer.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookProductionProgress` (data class) | public | 单章制作进度：章节索引、标题、已完成/总片段数 |
| `AudiobookProductionSummary` (data class) | public | 整体制作摘要：已完成片段数、总片段数、就绪章节数 |
| `AudiobookProducer` (class) | public `@Singleton` | 有声书合成执行器：按章逐段合成 AI 语音、写入数据库、更新章节状态 |

**AudiobookProducer 关键方法：**

```kotlin
suspend fun produce(
    bookId: Long,
    chapterIndices: List<Int>,
    onProgress: suspend (AudiobookProductionProgress) -> Unit = {}
): AudiobookProductionSummary
```

---

### AudiobookProductionWorker.kt

**文件路径：** `ai/audiobook/AudiobookProductionWorker.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookProductionEntryPoint` (interface) | public `@EntryPoint` | Hilt 入口点，用于 Worker 中获取 AudiobookProducer |
| `AudiobookProductionWorker` (class) | public | WorkManager 后台合成 Worker：前台通知、进度上报、失败重试 |

**AudiobookProductionWorker 关键方法：**

```kotlin
override suspend fun doWork(): Result
override suspend fun getForegroundInfo(): ForegroundInfo

companion object {
    fun enqueue(context: Context, bookId: Long, chapters: List<Int>)
    fun pause(context: Context, bookId: Long)
    fun uniqueWorkName(bookId: Long): String
}
```

---

### AudiobookScriptAgent.kt

**文件路径：** `ai/audiobook/AudiobookScriptAgent.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookScriptResult` (data class) | public | 剧本生成结果：片段列表、是否使用 AI、章节标题、正文 |
| `AudiobookScriptAgent` (class) | public `@Singleton` | 有声书剧本生成：本地规则先分段，AI 补充角色归因与情绪标注 |

**AudiobookScriptAgent 关键方法：**

```kotlin
suspend fun generate(
    bookId: Long,
    chapterIndex: Int,
    useAi: Boolean
): AudiobookScriptResult
```

**内部辅助函数：**
- `resolveAudiobookRole(roles, proposedName)` — 角色名匹配（支持别名、模糊匹配）

---

### AudiobookScriptParser.kt

**文件路径：** `ai/audiobook/AudiobookScriptParser.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ParsedAudiobookSegment` (data class) | public | 解析后的分段：起止偏移、角色名、情绪、表演指令 |
| `ParsedAudiobookAssignment` (data class) | public | 解析后的 AI 标注：分段索引、角色、置信度、证据、情绪、指令 |
| `AudiobookScriptParser` (object) | public | AI 剧本 JSON 解析器：容忍代码块围栏、多种字段名变体 |

**AudiobookScriptParser 关键方法：**

```kotlin
fun parseAssignments(raw: String, validIndices: Set<Int>): List<ParsedAudiobookAssignment>
fun parse(raw: String, textLength: Int): List<ParsedAudiobookSegment>
```

---

### AudiobookRoleExtractor.kt

**文件路径：** `ai/audiobook/AudiobookRoleExtractor.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookRoleExtractionResult` (data class) | public | 角色抽取结果：角色列表、是否使用 AI |
| `AudiobookRoleExtractor` (class) | public `@Singleton` | 从章节样本中抽取角色并分配音色：本地规则为底，AI 增强 |

**AudiobookRoleExtractor 关键方法：**

```kotlin
suspend fun extract(bookId: Long, useAi: Boolean): AudiobookRoleExtractionResult
```

---

### DialogueRuleSegmenter.kt

**文件路径：** `ai/audiobook/DialogueRuleSegmenter.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookSegmentKind` (enum) | public | 分段类型：NARRATION（旁白）/ DIALOGUE（对白） |
| `DraftAudiobookSegment` (data class) | public | 草稿分段：起止偏移、角色名、类型、置信度 |
| `DialogueRuleSegmenter` (object) | public | 本地规则对白/旁白切分器：基于引号与破折号识别对白，推断说话人 |

**DialogueRuleSegmenter 关键方法：**

```kotlin
fun segment(text: String): List<DraftAudiobookSegment>
```

---

### VoiceAssignmentParser.kt

**文件路径：** `ai/audiobook/VoiceAssignmentParser.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `VoiceAssignmentParser` (object) | public | 角色→音色分配 JSON 解析器：支持对象与数组两种格式 |

**VoiceAssignmentParser 关键方法：**

```kotlin
fun parse(raw: String, allowedVoiceIds: Set<String>): Map<String, String>
```

---

### AudiobookAttributionPlanner.kt

**文件路径：** `ai/audiobook/AudiobookAttributionPlanner.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookAttributionBatch` (data class) | internal | 单个归因批次：目标分段索引集合 + 标记上下文文本 |
| `buildAudiobookAttributionBatches()` (fun) | internal | 将长章切分为多个归因批次，控制上下文长度与目标数量 |

---

### AudiobookCostEstimator.kt

**文件路径：** `ai/audiobook/AudiobookCostEstimator.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AudiobookCostEstimate` (data class) | public | 制作成本估算：总字数、片段数、AI/系统片段数、预估费用 |
| `AudiobookCostEstimator` (object) | public | 按字数与引擎类型估算有声书制作费用 |

**AudiobookCostEstimator 关键方法：**

```kotlin
fun estimate(
    characterCounts: List<Int>,
    engines: List<String>,
    pricePerTenThousandChars: Double
): AudiobookCostEstimate
```

---

## ai/agent/ — AI Agent 工具

### AgentLoop.kt

**文件路径：** `ai/agent/AgentLoop.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AgentEvent` (sealed interface) | public | Agent 执行事件流：Text / Reasoning / RoundCommitted / ToolRun / ToolFinished |
| `AgentLoop` (class) | public `@Singleton` | Agent 主循环：流式对话 + 工具调用 + 消息持久化 + 滚动摘要 + 记忆窗口 |
| `Streamer` (fun interface) | public | 单轮模型流式接口，可注入用于测试 |

**AgentLoop 关键方法：**

```kotlin
// 主会话循环（带持久化、记忆、摘要）
fun run(
    conversationId: Long,
    tools: List<AgentTool>,
    systemPrompt: String? = null,
    modelRole: ModelRole = ModelRole.CHAT
): Flow<AgentEvent>

// 轻量独立循环（不落库，用于段评讨论等）
fun runDetached(
    history: List<ChatMessage>,
    tools: List<AgentTool>,
    maxRounds: Int = DETACHED_MAX_ROUNDS,
    modelRole: ModelRole = ModelRole.CHAT
): Flow<AgentEvent>
```

---

### AgentTool.kt

**文件路径：** `ai/agent/AgentTool.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AgentTool` (interface) | public | Agent 可调用的本地能力抽象：spec（模型可见）+ displayName（用户可见）+ execute |

**AgentTool 接口定义：**

```kotlin
interface AgentTool {
    val spec: ToolSpec
    val displayName: String
    suspend fun execute(arguments: JsonObject): String
}
```

---

### ReaderToolset.kt

**文件路径：** `ai/agent/ReaderToolset.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MemoryScope` (data class) | public | 工具的记忆可见范围配置：长期记忆开关、跨书检索、面具 ID |
| `ReaderToolset` (class) | public `@Singleton` | 阅读侧 Agent 工具集工厂：为指定书籍构建可用工具列表 |
| `WebSearchTool` (class) | private | 互联网搜索工具 |
| `WebScrapeTool` (class) | private | 网页正文抓取工具 |
| `GetReadingProgressTool` (class) | private | 查询书籍与阅读进度工具 |
| `ReadBookSectionTool` (class) | internal | 读取指定已读章节原文工具 |
| `SearchBookTool` (class) | internal | 书内向量+BM25 混合检索工具 |
| `AddAnnotationTool` (class) | private | 添加段落批注工具 |
| `GenerateImageTool` (class) | private | 生成并保存插图工具 |
| `SynthesizeSpeechTool` (class) | private | 合成并缓存语音工具 |
| `WriteNoteTool` (class) | private | 写读书笔记工具 |
| `SavePlotSummaryTool` (class) | private | 保存剧情梗概工具 |
| `RecallMemoryTool` (class) | internal | 角色长期记忆检索工具 |
| `ChapterDocument` (data class) | internal | 章节文档：索引、标题、正文 |

**ReaderToolset 关键方法：**

```kotlin
fun forBook(
    bookId: Long,
    personaId: Long? = null,
    conversationId: Long? = null,
    enabledTools: Collection<String>? = null,
    readingScope: ReadingScope,
    memoryScope: MemoryScope = MemoryScope()
): List<AgentTool>
```

---

### ReaderToolsetReadback.kt

**文件路径：** `ai/agent/ReaderToolsetReadback.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ProgressOverview` (data class) | internal | 阅读进度概览数据结构 |
| `ListChaptersTool` (class) | internal | 查看章节目录工具 |
| `ListAnnotationsTool` (class) | internal | 查看划线批注工具 |
| `ListNotesTool` (class) | internal | 查看笔记与梗概工具 |
| `NoteWriteTarget` (sealed interface) | internal | 笔记写入目标：Create / Update / Reject |
| `PromptAnnotation` (data class) | internal | 提示词用的批注格式 |

**关键内部函数：**
- `formatProgressOverview()` — 格式化阅读进度文本
- `formatChapterOutline()` — 格式化章节目录
- `formatAnnotationList()` — 格式化批注列表
- `formatNoteIndex()` / `formatNoteContent()` — 格式化笔记
- `resolveNoteWriteTarget()` — 解析笔记写入目标（新建/更新/拒绝）
- `locateExactQuote()` — 精确定位原文引文

---

### AnnotationDiscussionService.kt

**文件路径：** `ai/agent/AnnotationDiscussionService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AnnotationDiscussionService.Event` (sealed interface) | public | 段评讨论 AI 应答事件：Text / ToolActivity / Done / Failed |
| `AnnotationDiscussionService` (class) | public `@Singleton` | 段落批注讨论串的 AI 应答服务：以角色身份对批注讨论作答 |

**AnnotationDiscussionService 关键方法：**

```kotlin
fun respond(
    bookId: Long,
    annotationId: Long,
    personaId: Long
): Flow<Event>
```

---

### CompanionToolRouter.kt

**文件路径：** `ai/agent/CompanionToolRouter.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `CompanionToolRouter` (object) | internal | 按用户意图关键词裁剪工具集合，避免每轮发送完整 tools schema |

**CompanionToolRouter 关键方法：**

```kotlin
fun available(
    personaEnabledTools: Set<String>,
    requiredTools: Set<String> = emptySet(),
    webSearchEnabled: Boolean,
    longTermMemoryEnabled: Boolean
): Set<String>

fun select(
    userText: String,
    sceneAvailable: Boolean,
    personaEnabledTools: Set<String>,
    requiredTools: Set<String> = emptySet(),
    webSearchEnabled: Boolean,
    longTermMemoryEnabled: Boolean
): Set<String>
```

---

### ToolCallSummary.kt

**文件路径：** `ai/agent/ToolCallSummary.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ToolCallSummary` (object) | public | 将工具调用参数 JSON 压缩为 UI「过程」卡的一行摘要 |

**ToolCallSummary 关键方法：**

```kotlin
fun summarize(toolName: String, argumentsJson: String?): String
```

---

## ai/chat/ — 聊天相关

### AiChatRepository.kt

**文件路径：** `ai/chat/AiChatRepository.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MessageEditResult` (data class) | public | 消息编辑结果：会话 ID、角色、是否需要重新生成 |
| `AiChatRepository` (class) | public `@Singleton` | 阅读侧统一会话仓库：持久化、新建/切换、编辑、删除、重 roll、分支 |

**AiChatRepository 关键方法：**

```kotlin
// 会话管理
suspend fun startConversation(
    bookId: Long?, title: String, type: String,
    systemPrompt: String, firstUserMessage: String?,
    personaId: Long? = null,
    parentConversationId: Long? = null,
    branchedFromMessageId: Long? = null
): Long

fun observeConversations(bookId: Long, personaId: Long, type: String): Flow<List<ConversationEntity>>
suspend fun findLatestConversation(bookId: Long, personaId: Long, type: String): ConversationEntity?
suspend fun getConversation(conversationId: Long): ConversationEntity?

// 消息管理
fun observeMessages(conversationId: Long): Flow<List<MessageEntity>>
suspend fun getMessages(conversationId: Long): List<MessageEntity>
suspend fun appendUserMessage(
    conversationId: Long, content: String,
    attachmentsJson: String? = null, maskId: Long = 0L,
    sourceScopeChapterIndex: Int = -1, sourceScopeCharOffset: Int = -1
)
suspend fun appendAssistantMessage(conversationId: Long, content: String)

// 编辑与分支
suspend fun editMessage(messageId: Long, content: String): MessageEditResult
suspend fun deleteMessage(messageId: Long)
suspend fun prepareReroll(assistantMessageId: Long): Long
suspend fun branchConversation(conversationId: Long, throughMessageId: Long): Long

// 其他
suspend fun renameConversation(conversationId: Long, title: String)
suspend fun deleteConversation(conversationId: Long)
```

---

### CompanionGenerationTracker.kt

**文件路径：** `ai/chat/CompanionGenerationTracker.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `CompanionGenerationTracker` (class) | public `@Singleton` | 后台生成回复的会话登记处：跟踪正在生成的会话，支持跨界面取消 |

**CompanionGenerationTracker 关键方法：**

```kotlin
fun observe(conversationId: Long): Flow<Boolean>
fun isActive(conversationId: Long): Boolean
fun begin(conversationId: Long, job: Job)
fun end(conversationId: Long)
fun cancel(conversationId: Long): Boolean
```

---

### ReplySuggestionService.kt

**文件路径：** `ai/chat/ReplySuggestionService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ReplySuggestionParser` (object) | internal | 建议回复 JSON 解析器：容忍代码块围栏与对象包裹 |
| `ReplySuggestionService` (class) | public `@Singleton` | 伴读输入区 AI 建议回复：根据对话历史拟三条可一键发送的短回复 |

**ReplySuggestionService 关键方法：**

```kotlin
suspend fun suggest(
    personaName: String,
    bookTitle: String,
    history: List<MessageEntity>
): List<String>
```

---

## ai/client/ — AI 客户端/API

### AiClientFactory.kt

**文件路径：** `ai/client/AiClientFactory.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ResolvedChatClient` (data class) | public | 解析后的对话客户端：client + options + provider + modelName |
| `ResolvedMediaClient` (data class) | public | 解析后的媒体客户端：client + provider + model |
| `ResolvedImageGeneration` (data class) | public | 生图统一出口：client + label |
| `AiClientFactory` (class) | public `@Singleton` | AI 客户端工厂：按模型角色解析 provider/model，构建对应方言的客户端 |

**AiClientFactory 关键方法：**

```kotlin
suspend fun forRole(role: ModelRole): ResolvedChatClient
fun forModel(provider: AiProviderEntity, model: AiModelEntity): ResolvedChatClient
suspend fun mediaForRole(role: ModelRole): ResolvedMediaClient
suspend fun imageGeneration(): ResolvedImageGeneration
```

---

### ChatApiClient.kt

**文件路径：** `ai/client/ChatApiClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ApiDialect` (enum) | public | API 方言枚举：OPENAI / OPENAI_RESPONSES / CLAUDE / GEMINI |
| `ReasoningEffort` (enum) | public | 思维链努力程度：LOW / MEDIUM / HIGH，各方言映射不同字段 |
| `PromptCacheTtl` (enum) | public | Anthropic 提示缓存有效期：FIVE_MINUTES / ONE_HOUR |
| `ChatOptions` (data class) | public | 每请求调优参数：温度、top_p、max_tokens、推理强度、缓存等 |
| `ChatApiClient` (interface) | public | 对话 API 客户端统一接口：流式对话、非流式对话、批量 embedding |

**ChatApiClient 接口定义：**

```kotlin
interface ChatApiClient {
    fun chatStream(
        messages: List<ChatMessage>,
        tools: List<ToolSpec> = emptyList(),
        options: ChatOptions = ChatOptions.Default
    ): Flow<ChatDelta>

    suspend fun chat(
        messages: List<ChatMessage>,
        options: ChatOptions = ChatOptions.Default
    ): String

    suspend fun embed(texts: List<String>): List<FloatArray>
}
```

---

### AiModels.kt

**文件路径：** `ai/client/AiModels.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ChatRole` (enum) | public | 消息角色：SYSTEM / USER / ASSISTANT / TOOL |
| `ToolCall` (data class) | public `@Serializable` | 模型请求的工具调用：id + name + arguments |
| `ToolSpec` (data class) | public | 工具声明：name + description + parameters(JSON Schema) |
| `ChatMessage` (data class) | public | 单条聊天消息：role + content + toolCalls + toolCallId + parts |
| `ChatPart` (sealed interface) | public | 多模态消息片段：Text / Image |
| `ChatDelta` (sealed interface) | public | 流式增量事件：Text / Reasoning / ToolCalls |
| `OpenAiToolCallAccumulator` (class) | internal | OpenAI 流式 tool_calls 片段累积器 |

---

### AiError.kt

**文件路径：** `ai/client/AiError.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AiClientException` (sealed class) | public | 用户可理解的 AI 客户端异常，全部带中文说明 |

**AiClientException 子类：**
- `NotConfigured(roleLabel)` — 尚未配置模型角色
- `MissingKey(providerName)` — Provider 缺少 API Key
- `InvalidKey` — API Key 无效或无权限（401）
- `RateLimited` — 请求过于频繁或额度不足（429）
- `Timeout` — 请求超时
- `Network` — 网络不可用
- `Cancelled` — 已停止生成
- `Unsupported(detail)` — 不支持的能力
- `Http(code, detail)` — HTTP 错误
- `Empty` — 服务返回空内容
- `Malformed(detail)` — 响应格式异常

---

### OpenAiCompatClient.kt

**文件路径：** `ai/client/OpenAiCompatClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `OpenAiCompatClient` (class) | public | OpenAI 兼容方言客户端：/chat/completions + /embeddings，SSE 流式 |

**OpenAiCompatClient 构造：**

```kotlin
class OpenAiCompatClient(
    baseUrl: String,
    private val apiKey: String,
    private val model: String,
    httpClient: OkHttpClient,
    private val chatEndpointPath: String = "",
    private val embeddingEndpointPath: String = "",
    extraJson: String = "{}"
) : ChatApiClient
```

---

### ClaudeClient.kt

**文件路径：** `ai/client/ClaudeClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ClaudeClient` (class) | public | 原生 Anthropic Messages 方言客户端：支持 prompt caching 与 extended thinking |

---

### GeminiClient.kt

**文件路径：** `ai/client/GeminiClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `GeminiClient` (class) | public | 原生 Google Gemini 方言客户端：generateContent / streamGenerateContent |

---

### OpenAiResponsesClient.kt

**文件路径：** `ai/client/OpenAiResponsesClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `OpenAiResponsesClient` (class) | public | OpenAI Responses API 方言客户端：/responses 端点 |

---

### OpenAiMediaClient.kt

**文件路径：** `ai/client/OpenAiMediaClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `GeneratedImage` (data class) | public | 生成图片结果：bytes / url / mediaType |
| `SynthesizedSpeech` (data class) | public | 合成语音结果：bytes + mediaType + generationId |
| `OpenAiMediaClient` (class) | public | OpenAI 兼容媒体端点客户端：生图 + TTS，支持 MiniMax/GmiCloud 等适配 |

**OpenAiMediaClient 关键方法：**

```kotlin
override suspend fun generateImages(
    prompt: String, count: Int, size: String?
): List<GeneratedImage>

suspend fun synthesizeSpeech(
    text: String, voiceId: String?, speed: Float?,
    volume: Float?, pitch: Int?, format: String?,
    emotion: String?, instruction: String?
): SynthesizedSpeech

override suspend fun materializeImage(image: GeneratedImage): ByteArray
```

---

### ImageGenerationClient.kt

**文件路径：** `ai/client/ImageGenerationClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ImageGenerationClient` (interface) | public | 生图客户端抽象：OpenAI 兼容与 NovelAI 各自实现 |

**ImageGenerationClient 接口定义：**

```kotlin
interface ImageGenerationClient {
    suspend fun generateImages(
        prompt: String, count: Int = 1, size: String? = null
    ): List<GeneratedImage>
    suspend fun materializeImage(image: GeneratedImage): ByteArray
}
```

---

### NovelAiImageClient.kt

**文件路径：** `ai/client/NovelAiImageClient.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `NovelAiImageClient` (class) | public | NovelAI 生图客户端：Danbooru tags、sampler、steps、scale 等参数 |

---

### 其他 client 文件

| 文件 | 核心类/Object | 功能描述 |
|------|-------------|---------|
| `ChatImageExtractor.kt` | - | 从模型响应中提取图片内容（多模态） |
| `EmotionDialectMapper.kt` | - | 情绪标签到各方言语音 API 参数的映射 |
| `MiniMaxSpeechPerformance.kt` | - | MiniMax 语音性能参数配置 |
| `RequestOverrides.kt` | `RequestOverrides` | 从 extraJson 解析请求覆盖项（headers/body） |
| `GlobalPresetChatApiClient.kt` | `GlobalPresetChatApiClient` | 全局提示词预设注入的装饰客户端 |

---

## ai/persona/ — 角色人设

### PersonaRepository.kt

**文件路径：** `ai/persona/PersonaRepository.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `PersonaRepository` (class) | public `@Singleton` | 角色卡 CRUD：内置模板与用户自建统一管理，头像文件联动清理 |

**PersonaRepository 关键方法：**

```kotlin
fun observePersonas(): Flow<List<PersonaEntity>>
suspend fun getPersonas(): List<PersonaEntity>
suspend fun getPersona(personaId: Long): PersonaEntity?
suspend fun save(persona: PersonaEntity): Long
suspend fun delete(personaId: Long)
```

---

### SillyTavernCardParser.kt

**文件路径：** `ai/persona/SillyTavernCardParser.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ImportedPersonaCard` (data class) | public | 从角色卡提取的人设字段：名称、描述、性格、问候语、示例对话、世界书、头像 |
| `SillyTavernCardParser` (object) | public | SillyTavern 角色卡解析器：支持 PNG 卡（V1/V2/V3）与纯 JSON 卡 |

**SillyTavernCardParser 关键方法：**

```kotlin
fun parse(bytes: ByteArray): ImportedPersonaCard?
```

---

### PersonaAvatarStore.kt

**文件路径：** `ai/persona/PersonaAvatarStore.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `PersonaAvatarStore` (class) | public `@Singleton` | 角色头像文件仓：私有目录存储，支持 PNG 立绘与相册选图 |

**PersonaAvatarStore 关键方法：**

```kotlin
suspend fun saveBytes(bytes: ByteArray): String
suspend fun saveFromUri(uri: Uri): String?
fun delete(path: String?)
```

---

## ai/memory/ — 记忆系统

### MemoryConsolidator.kt

**文件路径：** `ai/memory/MemoryConsolidator.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MemoryConsolidationOutcome` (sealed interface) | public | 记忆固化结果：Completed / NotReady / Skipped / Failed |
| `MemoryBatch` (data class) | internal | 一批待固化消息及其中继消息 ID |
| `MemoryBatchPlanner` (object) | internal | 固化批次规划器：常规每 30 条，关闭时剩余 10 条也固化 |
| `MemorySummaryParser` (object) | internal | 记忆摘要 JSON 解析器 |
| `MemoryConsolidator` (class) | public `@Singleton` | 长期记忆固化核心：CHEAP 提炼 + EMBEDDING 向量化 + 写入向量库 + 用户画像更新 |

**MemoryConsolidator 关键方法：**

```kotlin
suspend fun consolidateAvailable(
    conversationId: Long,
    forceOnClose: Boolean = false
): MemoryConsolidationOutcome
```

---

### MemoryConsolidationWorker.kt

**文件路径：** `ai/memory/MemoryConsolidationWorker.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MemoryConsolidationEntryPoint` (interface) | public `@EntryPoint` | Hilt 入口点，用于 Worker 获取 MemoryConsolidator 与 RollingSummarizer |
| `MemoryConsolidationWorker` (class) | public | WorkManager 后台记忆固化 Worker：固化在前、提要在后 |

---

### PersonaMemoryRepository.kt

**文件路径：** `ai/memory/PersonaMemoryRepository.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `StoredMemory` (data class) | public | 记忆管理页可见的单条记忆：id + summary + createdAt + bookId + maskId |
| `PersonaMemoryRepository` (class) | public `@Singleton` | 角色记忆库读写门面：分页查询、删除、清空、用户画像管理 |

**PersonaMemoryRepository 关键方法：**

```kotlin
suspend fun count(personaId: Long): Long
suspend fun page(personaId: Long, offset: Int, limit: Int): List<StoredMemory>
suspend fun delete(id: Long)
suspend fun clear(personaId: Long)
suspend fun profile(personaId: Long): String
suspend fun saveProfile(personaId: Long, profile: String)
```

---

### RollingSummarizer.kt

**文件路径：** `ai/memory/RollingSummarizer.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `RollingSummarizer` (class) | public `@Singleton` | 会话前情提要生成器：填补「滑出窗口但尚未固化」的上下文裂缝 |

**RollingSummarizer 关键方法：**

```kotlin
suspend fun refresh(conversationId: Long): Boolean
fun block(rollingSummary: String): String?
```

---

### RollingSummaryPlanner.kt

**文件路径：** `ai/memory/RollingSummaryPlanner.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `RollingSummaryWork` (data class) | internal | 待摘要工作：消息列表 + 中继 ID |
| `RollingSummaryPlanner` (object) | internal | 滚动摘要规划器：决定何时把滑出窗口的消息压成前情提要 |

---

### MemoryOperationParser.kt

**文件路径：** `ai/memory/MemoryOperationParser.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MemoryOperation` (sealed interface) | internal | 记忆操作：Add / Update / Delete / NoOp |
| `MemoryOperationParser` (object) | internal | 固化操作数组解析器：容错解析 ADD/UPDATE/DELETE/NOOP |

---

### UserProfileParser.kt

**文件路径：** `ai/memory/UserProfileParser.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `MemoryConsolidationDraft` (data class) | internal | 固化产出草稿：操作列表 + 用户画像改写（可选） |
| `UserProfileParser` (object) | internal | 用户画像解析器：从固化响应中提取画像整段改写 |

---

## ai/embedding/ — 向量嵌入

### BookEmbeddingPipeline.kt

**文件路径：** `ai/embedding/BookEmbeddingPipeline.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `BookEmbeddingPipeline` (class) | public `@Singleton` | 整书 embedding 管线：解析模型、读章节、交给 ChapterEmbedder、进度追踪 |

**BookEmbeddingPipeline 关键方法：**

```kotlin
suspend fun embedBook(bookId: Long): EmbedOutcome
```

---

### BookEmbeddingScheduler.kt

**文件路径：** `ai/embedding/BookEmbeddingScheduler.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `BookEmbeddingScheduler` (interface) | public | 单本书索引调度接口：入队/取消，实现由 importer 层提供 |

**BookEmbeddingScheduler 接口定义：**

```kotlin
interface BookEmbeddingScheduler {
    fun enqueueForBook(bookId: Long, resetBookIndex: Boolean = false)
    fun cancelForBook(bookId: Long)
}
```

---

### ChapterEmbedder.kt

**文件路径：** `ai/embedding/ChapterEmbedder.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `EmbedOutcome` (sealed interface) | public | 整书 embedding 结局：Completed / Skipped / Failed |
| `ChapterEmbedder` (class) | public `@Singleton` | 章节切片 → 批量 embedding → ObjectBox 的流式核心，支持断点续跑 |

**ChapterEmbedder 关键方法：**

```kotlin
suspend fun embedChapters(
    bookId: Long,
    chapters: List<ChapterEntity>,
    readText: suspend (ChapterEntity) -> String,
    embed: suspend (List<String>) -> List<FloatArray>,
    onProgress: suspend (indexedChapters: Int, totalChapters: Int) -> Unit = { _, _ -> }
): EmbedOutcome
```

---

### EmbeddingProgressTracker.kt

**文件路径：** `ai/embedding/EmbeddingProgressTracker.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `EmbeddingIndexStage` (enum) | public | 书籍向量索引阶段：DISABLED / NOT_CONFIGURED / QUEUED / INDEXING / READY / BLOCKED / FAILED |
| `BookEmbeddingProgress` (data class) | public | 单本书索引进度：阶段、已索引/总章节数、模型名、消息 |
| `LibraryEmbeddingProgress` (data class) | public | 书库级索引进度汇总：阶段、章节数、启用/总书籍数、当前书籍 |
| `EmbeddingProgressTracker` (class) | public `@Singleton` | 向量索引进度追踪器：StateFlow 驱动 UI 展示 |

---

## ai/media/ — 媒体生成

### AiMediaGenerationService.kt

**文件路径：** `ai/media/AiMediaGenerationService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AgentMediaResult` (data class) | public `@Serializable` | Agent 媒体生成结果：状态、类型、ID、路径、消息（编解码用于工具返回） |
| `CachedSpeech` (data class) | public | 缓存语音：路径 + 媒体类型 + 是否命中缓存 |
| `SpeechCacheKey` (object) | internal | 语音缓存键生成：SHA-256 哈希所有影响参数 |
| `AiMediaGenerationService` (class) | public `@Singleton` | Agent 与划线菜单共用的媒体落盘服务：插图生成 + 语音合成缓存 |

**AiMediaGenerationService 关键方法：**

```kotlin
suspend fun generateIllustration(
    bookId: Long, chapterIndex: Int?, charOffset: Int?,
    sourceText: String, prompt: String, personaId: Long?
): IllustrationEntity

suspend fun synthesizeSpeech(
    bookId: Long, text: String, voiceId: String?,
    speed: Float?, volume: Float?, pitch: Int?,
    format: String? = null, emotion: String? = null,
    instruction: String? = null
): CachedSpeech
```

---

### BookCoverService.kt

**文件路径：** `ai/media/BookCoverService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `OnlineBookCover` (data class) | public | 在线书籍封面：标题、作者、图片 URL、来源 |
| `OnlineBookCoverSearchResult` (data class) | public | 封面搜索结果：封面列表、查询词、是否 AI 增强 |
| `BookCoverGenerationProgress` (data class) | public | 封面生成进度：比例 + 消息 |
| `BookCoverService` (class) | public `@Singleton` | 书籍封面服务：在线搜索 + AI 生成封面 |

---

### ImagePromptComposer.kt

**文件路径：** `ai/media/ImagePromptComposer.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ImagePromptFormat` (enum) | public | 提示词格式：NATURAL_LANGUAGE / NOVELAI_DANBOORU |
| `ImagePromptComposer` (class) | public `@Singleton` | 生图提示词改写器：按当前后端方言改写提示词（自然语言 ↔ Danbooru tags） |

**ImagePromptComposer 关键方法：**

```kotlin
suspend fun compose(source: String): String
suspend fun currentFormat(): ImagePromptFormat
```

---

### SharedGenerationRegistry.kt

**文件路径：** `ai/media/SharedGenerationRegistry.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `SharedGenerationRegistry` (class) | internal | 共享生成任务注册表：同 key 任务只跑一份，挂到外部 scope 避免切页取消丢失结果 |

---

## ai/prompt/ — 提示词

### CompanionContextBuilder.kt

**文件路径：** `ai/prompt/CompanionContextBuilder.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `BookProgress` (data class) | public | 书籍进度快照：标题、作者、章节数、当前章节等 |
| `ConversationShape` (data class) | public | 对话形态配置：多气泡 + 语音能力（能力关闭则一字不写） |
| `CompanionContextBuilder` (class) | public `@Singleton` | 伴读上下文构建器：组装系统提示词（人设→进度→防剧透→记忆→场景），按预算裁剪 |

**CompanionContextBuilder 关键方法：**

```kotlin
suspend fun build(
    persona: PersonaEntity?,
    bookId: Long?,
    scene: String? = null,
    memoryQuery: String? = null,
    readingScope: ReadingScope,
    conversationShape: ConversationShape = ConversationShape(),
    budgetChars: Int = DEFAULT_BUDGET_CHARS
): String
```

---

### GlobalPromptInjector.kt

**文件路径：** `ai/prompt/GlobalPromptInjector.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `GlobalPromptInjector` (object) | public | 全局提示词预设注入器：按位置（system 前后 / last user 前后）注入启用的预设 |

**GlobalPromptInjector 关键方法：**

```kotlin
fun inject(
    messages: List<ChatMessage>,
    presets: List<GlobalPromptPreset>
): List<ChatMessage>
```

---

### SelectionPrompts.kt

**文件路径：** `ai/selection/SelectionPrompts.kt` → 实际路径 `ai/prompt/SelectionPrompts.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `SelectionAiAction` (enum) | public | 选段 AI 操作：TRANSLATE（翻译）/ ANALYZE（解析）/ ASK（提问） |
| `SelectionPrompts` (object) | public | 选段操作提示词模板：翻译/解析/提问 三种模式的 system 与首条消息 |

**SelectionPrompts 关键方法：**

```kotlin
fun system(bookTitle: String, chapterTitle: String): String
fun firstMessage(action: SelectionAiAction, selection: String, context: String): String
```

---

## ai/provider/ — 提供商管理

### AiProviderRepository.kt

**文件路径：** `ai/provider/AiProviderRepository.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `AiProviderDraft` (data class) | public | Provider 草稿：名称、地址、类型、格式、适配器、extraJson、API Key |
| `AiModelDraft` (data class) | public | 模型草稿：模型名、类型、聊天格式、端点路径、extraJson |
| `AiProviderRepository` (class) | public `@Singleton` | AI Provider 仓库：Provider CRUD + 模型 CRUD + 角色分配 + API Key 管理 |

**AiProviderRepository 关键方法：**

```kotlin
fun observeProviders(): Flow<List<AiProviderEntity>>
fun observeModels(): Flow<List<AiModelEntity>>
fun observeAssignments(): Flow<List<ModelAssignmentEntity>>
suspend fun save(draft: AiProviderDraft): Long
suspend fun saveModel(providerId: Long, draft: AiModelDraft): Long
suspend fun deleteProvider(providerId: Long)
suspend fun deleteModel(modelId: Long)
suspend fun assignRole(role: ModelRole, modelId: Long)
suspend fun apiKeyFor(provider: AiProviderEntity): String?
```

---

### ModelCatalog.kt

**文件路径：** `ai/provider/ModelCatalog.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `CatalogModel` (data class) | public | 目录模型：模型名 + 类型 + 端点路径 |
| `ModelCatalogResult` (sealed interface) | public | 模型目录结果：Success / Failure |
| `ModelCatalogFetcher` (class) | public `@Singleton` | 模型目录拉取器：从 Provider 拉取模型列表，识别 CHAT/EMBEDDING/TTS/IMAGE 类型 |

**ModelCatalogFetcher 关键方法：**

```kotlin
suspend fun fetch(provider: AiProviderEntity, apiKey: String): ModelCatalogResult
```

---

### ProviderConnectionTester.kt

**文件路径：** `ai/provider/ProviderConnectionTester.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ConnectionTestResult` (sealed interface) | public | 连接测试结果：Success / Failure |
| `ProviderConnectionTester` (class) | public `@Singleton` | Provider 连通性测试器：Ping 模型目录端点，按方言适配请求头 |

**ProviderConnectionTester 关键方法：**

```kotlin
suspend fun test(provider: AiProviderEntity, apiKey: String?): ConnectionTestResult
```

---

### ProviderProtocolPolicy.kt

**文件路径：** `ai/provider/ProviderProtocolPolicy.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ModelProtocolRoute` (sealed interface) | public | 模型协议路由：Chat(dialect) / Embedding(dialect) / Media / Unsupported |
| `ProviderProtocolPolicy` (object) | public | 提供商协议策略：按 adapter+模型类型决定路由与方言 |

**ProviderProtocolPolicy 关键方法：**

```kotlin
fun supportedChatDialects(adapter: AiProviderAdapter): List<ApiDialect>
fun defaultChatDialect(adapter: AiProviderAdapter): ApiDialect
fun providerChatDialect(provider: AiProviderEntity): ApiDialect
fun modelChatDialect(provider: AiProviderEntity, model: AiModelEntity): ApiDialect
fun route(provider: AiProviderEntity, model: AiModelEntity): ModelProtocolRoute
fun isSupported(provider: AiProviderEntity, model: AiModelEntity): Boolean
```

---

## ai/search/ — 网页搜索

### WebSearchService.kt

**文件路径：** `ai/search/WebSearchService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `WebSearchResult` (data class) | public | 网页搜索结果：标题 + URL + 摘要 |
| `WebScrapeResult` (data class) | public | 网页抓取结果：标题 + URL + 正文内容 |
| `WebImageSearchResult` (data class) | public | 图片搜索结果：标题 + 图片 URL + 页面 URL + 来源 + 尺寸 |
| `WebSearchService` (class) | public `@Singleton` | 网页搜索服务：支持 Firecrawl / Exa / Tavily 三家提供商 |

**WebSearchService 关键方法：**

```kotlin
suspend fun search(query: String, limit: Int): List<WebSearchResult>
suspend fun scrape(url: String): WebScrapeResult
suspend fun searchImages(query: String, limit: Int): List<WebImageSearchResult>
```

---

### WebSearchSettingsStore.kt

**文件路径：** `ai/search/WebSearchSettingsStore.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `WebSearchProvider` (enum) | public `@Serializable` | 搜索提供商枚举：FIRECRAWL / EXA / TAVILY，含默认端点 |

---

## ai/companion/ — 陪伴功能

### ProactiveAnnotationService.kt

**文件路径：** `ai/companion/ProactiveAnnotationService.kt`

| 类/接口/Object | 可见性 | 一句话功能描述 |
|----------------|--------|---------------|
| `ProactiveAnnotationDraft` (data class) | internal | 主动批注草稿：引文 + 批注 + 样式 + 语音 + 生图提示词 |
| `ProactiveAnnotationParser` (object) | internal | 主动批注 JSON 解析器：容错解析数组或对象包裹 |
| `ProactiveAnnotationService` (class) | public `@Singleton` | 主动批注生成服务：读完一章后角色主动添加批注、语音、插图（受配额限制） |

**ProactiveAnnotationService 关键方法：**

```kotlin
suspend fun generateForCompletedChapter(bookId: Long, chapterIndex: Int)
```

---

---

## 核心类索引（按功能分类）

### 一、听书引擎（Listen Engine）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `ListenEngine` | `ai/listen/ListenEngine.kt` | 听书核心引擎：逐句朗读、自动翻章、AI/系统 TTS 双模式、预取、睡眠定时 |
| `ListenService` | `ai/listen/ListenService.kt` | 前台媒体服务：MediaSession + 通知栏控制 + 后台保活 |
| `ListenAudioFocusPolicy` | `ai/listen/ListenAudioFocusPolicy.kt` | 音频焦点策略：决定焦点变更后的播放动作 |

### 二、有声书制作（Audiobook Production）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AudiobookProducer` | `ai/audiobook/AudiobookProducer.kt` | 合成执行器：按章逐段合成 AI 语音并更新状态 |
| `AudiobookProductionWorker` | `ai/audiobook/AudiobookProductionWorker.kt` | WorkManager 后台合成 Worker |
| `AudiobookScriptAgent` | `ai/audiobook/AudiobookScriptAgent.kt` | 剧本生成：本地规则 + AI 角色归因与情绪标注 |
| `AudiobookRoleExtractor` | `ai/audiobook/AudiobookRoleExtractor.kt` | 角色抽取与音色分配 |
| `DialogueRuleSegmenter` | `ai/audiobook/DialogueRuleSegmenter.kt` | 本地对白/旁白切分规则 |
| `AudiobookScriptParser` | `ai/audiobook/AudiobookScriptParser.kt` | AI 剧本 JSON 解析 |
| `AudiobookCostEstimator` | `ai/audiobook/AudiobookCostEstimator.kt` | 制作成本估算 |

### 三、AI Agent 框架

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AgentLoop` | `ai/agent/AgentLoop.kt` | Agent 主循环：流式对话 + 工具调用 + 持久化 + 摘要 + 记忆窗口 |
| `AgentTool` | `ai/agent/AgentTool.kt` | 工具接口抽象 |
| `ReaderToolset` | `ai/agent/ReaderToolset.kt` | 阅读侧工具集工厂（检索/批注/笔记/生图/语音等） |
| `CompanionToolRouter` | `ai/agent/CompanionToolRouter.kt` | 按用户意图关键词裁剪工具集 |
| `ToolCallSummary` | `ai/agent/ToolCallSummary.kt` | 工具调用摘要压缩（UI 展示用） |
| `AnnotationDiscussionService` | `ai/agent/AnnotationDiscussionService.kt` | 段评讨论串 AI 应答 |

### 四、AI 客户端 / API 层

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AiClientFactory` | `ai/client/AiClientFactory.kt` | 客户端工厂：按角色解析并构建对应方言客户端 |
| `ChatApiClient` | `ai/client/ChatApiClient.kt` | 对话 API 统一接口 |
| `OpenAiCompatClient` | `ai/client/OpenAiCompatClient.kt` | OpenAI 兼容方言实现（覆盖大部分中转商） |
| `ClaudeClient` | `ai/client/ClaudeClient.kt` | Anthropic 原生方言实现 |
| `GeminiClient` | `ai/client/GeminiClient.kt` | Google Gemini 原生方言实现 |
| `OpenAiMediaClient` | `ai/client/OpenAiMediaClient.kt` | 媒体（生图+TTS）OpenAI 兼容客户端 |
| `AiClientException` | `ai/client/AiError.kt` | 统一异常体系（用户可读中文消息） |
| `ChatOptions` | `ai/client/ChatApiClient.kt` | 每请求调优参数 |

### 五、角色人设（Persona）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `PersonaRepository` | `ai/persona/PersonaRepository.kt` | 角色卡 CRUD |
| `SillyTavernCardParser` | `ai/persona/SillyTavernCardParser.kt` | SillyTavern 角色卡导入解析 |
| `PersonaAvatarStore` | `ai/persona/PersonaAvatarStore.kt` | 角色头像文件管理 |

### 六、记忆系统（Memory System）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `MemoryConsolidator` | `ai/memory/MemoryConsolidator.kt` | 长期记忆固化核心：提炼 + 向量化 + 写入 + 画像更新 |
| `MemoryConsolidationWorker` | `ai/memory/MemoryConsolidationWorker.kt` | 后台固化 Worker |
| `RollingSummarizer` | `ai/memory/RollingSummarizer.kt` | 会话前情提要生成（填补上下文裂缝） |
| `PersonaMemoryRepository` | `ai/memory/PersonaMemoryRepository.kt` | 角色记忆管理页读写门面 |
| `MemoryOperationParser` | `ai/memory/MemoryOperationParser.kt` | ADD/UPDATE/DELETE 操作解析 |
| `UserProfileParser` | `ai/memory/UserProfileParser.kt` | 用户画像解析 |

### 七、向量嵌入（Embedding）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `BookEmbeddingPipeline` | `ai/embedding/BookEmbeddingPipeline.kt` | 整书 embedding 管线编排 |
| `ChapterEmbedder` | `ai/embedding/ChapterEmbedder.kt` | 章节切片 + 批量 embedding + 落库核心 |
| `BookEmbeddingScheduler` | `ai/embedding/BookEmbeddingScheduler.kt` | 索引任务调度接口 |
| `EmbeddingProgressTracker` | `ai/embedding/EmbeddingProgressTracker.kt` | 索引进度追踪与 UI 状态 |

### 八、媒体生成（Media Generation）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AiMediaGenerationService` | `ai/media/AiMediaGenerationService.kt` | 插图生成 + 语音合成缓存（Agent 与 UI 共用） |
| `BookCoverService` | `ai/media/BookCoverService.kt` | 书籍封面搜索与 AI 生成 |
| `ImagePromptComposer` | `ai/media/ImagePromptComposer.kt` | 提示词方言改写（自然语言 ↔ Danbooru） |

### 九、聊天与会话（Chat）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AiChatRepository` | `ai/chat/AiChatRepository.kt` | 会话与消息持久化：CRUD + 编辑 + 重 roll + 分支 |
| `CompanionGenerationTracker` | `ai/chat/CompanionGenerationTracker.kt` | 后台生成任务登记与取消 |
| `ReplySuggestionService` | `ai/chat/ReplySuggestionService.kt` | AI 建议回复生成 |

### 十、提示词系统（Prompt System）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `CompanionContextBuilder` | `ai/prompt/CompanionContextBuilder.kt` | 伴读系统提示词构建（人设+进度+记忆+场景+预算裁剪） |
| `GlobalPromptInjector` | `ai/prompt/GlobalPromptInjector.kt` | 全局预设注入 |
| `SelectionPrompts` | `ai/prompt/SelectionPrompts.kt` | 选段操作提示词模板 |

### 十一、提供商管理（Provider Management）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `AiProviderRepository` | `ai/provider/AiProviderRepository.kt` | Provider + 模型 + 角色分配 CRUD |
| `ProviderProtocolPolicy` | `ai/provider/ProviderProtocolPolicy.kt` | 协议路由策略（按 adapter 决定方言与能力） |
| `ModelCatalogFetcher` | `ai/provider/ModelCatalog.kt` | 模型目录拉取 |
| `ProviderConnectionTester` | `ai/provider/ProviderConnectionTester.kt` | 连通性测试 |

### 十二、网页搜索（Web Search）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `WebSearchService` | `ai/search/WebSearchService.kt` | 网页搜索 + 抓取 + 图片搜索（Firecrawl/Exa/Tavily） |
| `WebSearchSettingsStore` | `ai/search/WebSearchSettingsStore.kt` | 搜索设置存储与提供商枚举 |

### 十三、主动陪伴（Proactive Companion）

| 核心类 | 文件 | 职责定位 |
|--------|------|---------|
| `ProactiveAnnotationService` | `ai/companion/ProactiveAnnotationService.kt` | 主动批注生成：读完一章后角色自动添加批注/语音/插图 |

---

## 附录：工具清单（Reader Toolset）

| 工具名 | 类别 | 功能 | 权限 |
|--------|------|------|------|
| `get_reading_progress` | 只读 | 查询书籍与阅读进度 | 基础 |
| `search_book` | 只读 | 书内向量+BM25 混合检索 | 基础 |
| `read_book_section` | 只读 | 读取指定已读章节原文 | 基础 |
| `list_chapters` | 只读 | 查看章节目录 | 基础 |
| `list_annotations` | 只读 | 查看划线批注 | 基础 |
| `list_notes` | 只读 | 查看笔记与梗概 | 基础 |
| `recall_memory` | 只读 | 回忆过往交流（长期记忆） | 记忆开关 |
| `add_annotation` | 写入 | 添加段落批注 | 角色白名单 |
| `write_note` | 写入 | 写读书笔记 | 角色白名单 |
| `save_plot_summary` | 写入 | 保存剧情梗概 | 角色白名单 |
| `generate_image` | 写入 | 生成并保存插图 | 角色白名单 |
| `synthesize_speech` | 写入 | 合成并缓存语音 | 角色白名单 |
| `web_search` | 联网 | 搜索互联网 | 网络搜索开关 |
| `web_scrape` | 联网 | 抓取网页正文 | 网络搜索开关 |

---
