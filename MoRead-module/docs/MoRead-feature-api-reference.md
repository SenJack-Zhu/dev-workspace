# MoRead Feature 层架构参考

> 扫描范围：`/data/user/work/MoRead-module/app/src/main/java/com/mozhi/reader/feature/`
>
> 本文档按模块分组，列出各模块的 **ViewModel**、**核心引擎/控制器类**、**Screen 级 Composable**，并在末尾给出 ViewModel 总索引表。

---

## 目录

- [1. feature/reader/ - 阅读器](#1-featurereader---阅读器)
  - [1.1 ViewModel 列表](#11-viewmodel-列表)
  - [1.2 核心引擎：排版引擎 (engine/)](#12-核心引擎排版引擎-engine)
  - [1.3 渲染层 (render/)](#13-渲染层-render)
  - [1.4 Screen 级 Composable](#14-screen-级-composable)
- [2. feature/listen/ - 听书 / 有声书制作](#2-featurelisten---听书--有声书制作)
  - [2.1 ViewModel 列表](#21-viewmodel-列表)
  - [2.2 Screen 级 Composable](#22-screen-级-composable)
- [3. feature/importer/ - 导入功能](#3-featureimporter---导入功能)
  - [3.1 ViewModel 列表](#31-viewmodel-列表)
  - [3.2 核心引擎/控制器类](#32-核心引擎控制器类)
  - [3.3 Screen 级 Composable](#33-screen-级-composable)
- [4. feature/bookshelf/ - 书架](#4-featurebookshelf---书架)
  - [4.1 ViewModel 列表](#41-viewmodel-列表)
  - [4.2 Screen 级 Composable](#42-screen-级-composable)
- [5. feature/settings/ - 设置页](#5-featuresettings---设置页)
  - [5.1 ViewModel 列表](#51-viewmodel-列表)
  - [5.2 Screen 级 Composable](#52-screen-级-composable)
- [6. feature/companion/ - 伴读角色](#6-featurecompanion---伴读角色)
  - [6.1 ViewModel 列表](#61-viewmodel-列表)
  - [6.2 Screen 级 Composable](#62-screen-级-composable)
- [7. feature/bookdetail/ - 书籍详情](#7-featurebookdetail---书籍详情)
  - [7.1 ViewModel](#71-viewmodel)
  - [7.2 Screen 级 Composable](#72-screen-级-composable)
- [8. feature/stats/ - 阅读统计](#8-featurestats---阅读统计)
  - [8.1 ViewModel](#81-viewmodel)
  - [8.2 Screen 级 Composable](#82-screen-级-composable)
- [9. ViewModel 总索引表](#9-viewmodel-总索引表)

---

## 1. feature/reader/ - 阅读器

最复杂的模块，包含主阅读界面、排版引擎、AI 伴读、搜索、批注等。

### 1.1 ViewModel 列表

#### 1.1.1 ReaderViewModel **[主 ViewModel]**

- **所在文件**：`feature/reader/ReaderViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<ReaderUiState>` — 阅读页全局状态
    - `book: BookEntity?` — 当前书籍
    - `chapters: List<ChapterEntity>` — 章节列表
    - `tocEntries: List<BookTocEntryEntity>` — 目录
    - `bookmarks: List<BookmarkEntity>` — 书签
    - `annotations: List<AnnotationEntity>` — 批注
    - `illustrations: List<IllustrationEntity>` — 插图
    - `repliedAnnotationIds: Set<Long>` — 有讨论回复的批注 ID
    - `showAiAnnotations: Boolean` — 是否显示 AI 批注
    - `lastAnnotationStyle / lastAnnotationColor` — 即划即改默认样式
    - `settings: ReaderSettings` — 阅读器设置
    - `currentChapterIndex / currentCharOffset / pageIndex / pageCount` — 阅读位置
    - `readingProgress / chapterProgress` — 阅读进度
    - `readingStats: ReaderStatistics` — 阅读统计（总时长、天数、连续天数、近7天）
    - `isLoading / isPreparingText / isContentReady` — 加载状态
    - `errorMessage: String?` — 错误信息
  - `events: Flow<ReaderEvent>` — 一次性事件通道
    - `ShowMessage` — 提示消息
    - `ConfirmFontImport` — 确认字体导入
    - `TextReplacementRuleSuggested` — AI 建议替换规则
- **关键 public 方法**：
  - **导航**：`goToChapter()`, `goToTocEntry()`, `goToPrevChapter()`, `goToNextChapter()`, `seekWithinChapter()`, `goToProgress()`, `goToBookmark()`, `goToPosition()`
  - **书签**：`toggleBookmark()`, `deleteBookmark()`
  - **批注**：`quickAnnotate()`, `updateAnnotationStyle()`, `updateAnnotationNote()`, `deleteAnnotation()`
  - **文本编辑**：`editSelectedText()`, `applyTextReplacementRules()`, `saveTextReplacementRule()`, `deleteTextReplacementRule()`, `generateTextReplacementRule()`
  - **章节重识别**：`reidentifyChapters(customRegex)`
  - **排版设置**：`setFontScale()`, `setFont()`, `setLineHeight()`, `setPageMargin()`, `setFontWeight()`, `setLetterSpacing()`, `setParagraphSpacing()`, `setFirstLineIndent()`, `setTextJustification()`, `setTheme()`, `setPageTurnAnimation()`, `setPageMode()` 等
  - **背景/主题**：`importBackgroundImage()`, `selectBackgroundImage()`, `clearBackgroundImage()`, `setBackgroundImageOpacity()`, `saveCustomTheme()`, `saveBookCustomTheme()`
  - **阅读计时**：`onReaderResumed()`, `onReaderPaused()`, `flushProgress()`
  - **EPUB 链接**：`previewEpubLink(link): EpubLinkPreview?`
  - **内容钩子**：`setContentHook(hook)` — Pane 注册内容变化回调
  - **听书辅助**：`isShowingPosition()`, `currentPageText()`
- **核心依赖**：`contentController: ReaderContentController` — 排版控制器

---

#### 1.1.2 ReaderSearchViewModel

- **所在文件**：`feature/reader/ReaderSearchViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<ReaderSearchUiState>`
    - `query: String` — 搜索关键词
    - `isSearching: Boolean` — 是否搜索中
    - `hits: List<BookSearchHit>` — 搜索结果
    - `completed: Boolean` — 是否已完成一轮完整扫描
- **关键 public 方法**：
  - `bind(bookId)` — 绑定书籍
  - `search(query)` — 执行搜索（IO 线程逐章扫描，边扫边出结果，最多 300 条）
  - `clear()` — 清除搜索

---

#### 1.1.3 ReaderCompanionViewModel

- **所在文件**：`feature/reader/ReaderCompanionViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<CompanionChatUiState>` — 伴读聊天状态
    - `persona: PersonaEntity?` — 当前角色
    - `conversationId: Long?` — 会话 ID
    - `messages: List<MessageEntity>` — 消息列表
    - `streamingText / isStreaming` — 流式输出状态
    - `executionSteps: List<AgentExecutionStep>` — Agent 工具调用步骤
    - `pendingAttachments: List<PendingAttachment>` — 待发送附件
    - `embeddingProgress: BookEmbeddingProgress?` — 嵌入进度
    - `suggestions: List<String>` — 回复建议
- **关键 public 方法**：
  - `bind(bookId)` — 绑定书籍
  - `sendMessage(text)` — 发送消息
  - `addAttachment(uri, isImage, name)` — 添加附件
  - `removeAttachment(uri)` — 移除附件
  - `retry()` — 重试
  - `stopStreaming()` — 停止流式输出
  - `selectPersona(personaId)` — 切换角色

---

#### 1.1.4 ReaderAiViewModel

- **所在文件**：`feature/reader/ReaderAiViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<ReaderAiUiState>` — 选段 AI 面板状态
    - `request: ReaderAiRequest?` — 当前请求（action + selection + context）
    - `conversationId: Long?` — 会话 ID
    - `messages: List<MessageEntity>` — 消息列表
    - `streamingText / isStreaming` — 流式输出
    - `toolStatus: String?` — 工具运行状态文案
    - `executionSteps: List<AgentExecutionStep>` — 执行步骤
    - `error: String?` — 错误信息
- **关键 public 方法**：
  - `start(request)` — 启动一次选段 AI 操作（解释/翻译/总结/提问等）
  - `sendFollowUp(text)` — 发送追问
  - `retry()` — 重试
  - `stopStreaming()` — 停止流式输出

---

#### 1.1.5 ReaderListenViewModel

- **所在文件**：`feature/reader/ReaderListenViewModel.kt`
- **核心 StateFlow**：
  - `state: StateFlow<ListenEngineState>` — 直接代理 `ListenEngine.state`
  - `sleepTimer: StateFlow<SleepTimerPlan?>` — 睡眠定时器
- **关键 public 方法**：
  - `start(bookId, chapterIndex, charOffset)` — 开始听书
  - `toggle()` — 播放/暂停
  - `stop()` — 停止
  - `prevSentence() / nextSentence()` — 上一句/下一句
  - `prevChapter() / nextChapter()` — 上一章/下一章
  - `seekTo(chapterIndex, charOffset)` — 跳转到指定位置
  - `setSleepTimer(plan)` — 设置睡眠定时
- **说明**：门面模式，全部逻辑在单例 `ListenEngine`，退出阅读页不打断播放。

---

#### 1.1.6 ReaderSelectionMediaViewModel

- **所在文件**：`feature/reader/ReaderSelectionMediaViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<SelectionMediaUiState>` — 选区媒体状态
    - `status: String?` — 状态提示
    - `isWorking: Boolean` — 是否工作中
    - `isPlaying: Boolean` — 是否播放中
    - `imagePath / imagePrompt` — 生成的图片
    - `imageGeneration: SelectionImageGeneration?` — 图片生成参数（支持重绘）
  - `events: Flow<SelectionMediaEvent>` — 事件通道
- **关键 public 方法**：
  - `speak(text)` — 朗读选中文本（按设置路由到系统 TTS 或云端模型）
  - `generateImage(bookId, chapterIndex, charOffset, sourceText, basePrompt)` — 生成插图
  - `rerollImage()` — 重绘图片
  - `stopPlaying()` — 停止播放

---

#### 1.1.7 AnnotationDiscussionViewModel

- **所在文件**：`feature/reader/AnnotationDiscussionViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<DiscussionUiState>` — 讨论串状态
    - `replies: List<AnnotationReplyEntity>` — 回复列表
    - `streaming: DiscussionStreaming?` — AI 正在生成的回复
    - `error: String?` — 错误信息
- **关键 public 方法**：
  - `open(annotationIds)` — 绑定讨论串（同锚点的全部批注 ID）
  - `reply(text)` — 用户发言
  - `aiRespond(personaId)` — 单角色 AI 应答
  - `multiRespond(personaIds)` — 多角色编排讨论
  - `deleteReply(replyId)` — 删除回复

---

### 1.2 核心引擎：排版引擎 (engine/)

#### 1.2.1 ReaderContentController **[核心控制器]**

- **所在文件**：`feature/reader/engine/ReaderContentController.kt`
- **定位**：Legado `ReadBook` + `TextPageFactory` 的移植版，三章窗口（prev/cur/next）管理器
- **核心数据结构**：
  - `ChapterMeta(index, title, charCount)` — 章节元数据
  - `RenderPage` — 输出给渲染层的页（`Laid` 已排版 / `Placeholder` 加载中）
- **核心属性**：
  - `chapterIndex: Int` — 当前章节索引
  - `charOffset: Int` — 当前字符偏移（唯一真相源，pageIndex 由它推导）
  - `pageIndex: Int` — 当前页索引
  - `pageCount: Int` — 当前章总页数
  - `isReady: Boolean` — 当前章是否已排版完成
- **核心方法**：
  - `setChapters(list)` — 设置章节列表
  - `setInlineImages(images)` — 设置行内图片
  - `updateEnvironment(spec, measure)` — 更新排版环境（视口/样式变化）
  - `openPosition(chapterIndex, charOffset)` — 打开指定位置
  - `jumpToChapter(index, offset)` — 跳转到章节
  - `jumpToProgress(progress)` — 按全书进度跳转
  - `seekWithinChapter(fraction)` — 章内按比例跳转
  - `curPage() / nextPage() / prevPage()` — 获取当前/下一页/上一页
  - `moveToNextPage() / moveToPrevPage()` — 翻页（提交翻页动画时调用）
  - `hasNextPage() / hasPrevPage()` — 是否可翻页
  - `scrollTo(chapter, offset)` — 滚动模式位置推进
  - `contextAround(range, radius)` — 获取选段附近上下文（AI 用）
  - `isDisplaying(chapter, offset)` — 听书自动翻页判断
  - `reloadFromSource()` — 本地文本修改后重载窗口
  - `invalidateEpubLayouts()` — 失效 EPUB 布局缓存并重排
- **Listener 回调**：
  - `onContentChanged(relativePosition)` — 内容变化（-1=仅上一页，0=全部，1=仅下一页）
  - `onPositionChanged(chapterIndex, charOffset, pageIndex, pageCount, bookProgress)` — 位置变化
  - `onContentError(chapterIndex, error)` — 当前章加载失败

---

#### 1.2.2 ChapterTypesetter **[纯文本排版器]**

- **所在文件**：`feature/reader/engine/ChapterTypesetter.kt`
- **定位**：Legado `TextChapterLayout` 的纯 Kotlin 移植版，负责纯文本章节排版
- **输入**：`TypesetSpec` + `TextMeasure` + 章节标题 + 正文 + 行内图片
- **输出**：`TextChapter`（已排版的章节，包含所有页面）
- **核心数据结构**：
  - `TypesetSpec` — 排版参数（像素单位，由渲染层从 ReaderSettings + density 解析）
    - `visibleWidth / visibleHeight` — 可见区域尺寸
    - `contentLineStep / titleLineStep` — 正文/标题行高
    - `paragraphSpacing / blankLineSpacing` — 段间距
    - `indentCharCount / justifyContent / bottomAlign` — 缩进/两端对齐/底部对齐
    - `syntaxHighlightRules` — 语法高亮规则
    - `publisherStyleMode / themeBackgroundArgb / themeTextArgb` — 主题相关
- **排版特性**：
  - 首行缩进（margin 方式，不注入 U+3000，保持正文偏移一致）
  - 段落首行自动识别为标题（与章名匹配时）
  - 两端对齐（CJK 字间均分 / 拉丁空格均分）
  - 底部对齐（满页时拉伸行间距）
  - 行内图片排版
  - 语法高亮（ReaderSyntaxRule）
  - 行内标记（批注/插图标记）
  - 溢出行压缩回退

---

#### 1.2.3 文本页面模型 (TextPageModel)

- **所在文件**：`feature/reader/engine/TextPageModel.kt`
- **核心类**：
  - `TextColumn` — 字符列（x 坐标范围 + 字符数据 + 语法样式 + 行内标记 + 超链接）
  - `TextLine` — 文本行（y 坐标范围 + 列列表 + 行内图片 + 装饰 + Ruby 注音）
  - `TextPage` — 文本页（页索引 + 行列表 + 起始偏移 + 字符数 + 装饰 + 背景）
    - `immersive: Boolean` — 特殊封面/卷首页隐藏页眉页脚
    - `hideHeader: Boolean` — 正文自带章标题时隐藏阅读器页眉
    - `trailingGap: Float` — 页末段间隙（滚动模式拼接用）
  - `TextChapter` — 已排版章节（章索引 + 标题 + 页面列表 + 正文长度）
    - `pageCount`, `page(index)`, `lastPage`, `isLastPage(index)`
    - `pageStartOffset(pageIndex)` — 某页起始字符偏移
    - `pageIndexAt(charOffset)` — 二分查找某偏移所在页
- **辅助数据类**：
  - `InlineImageSource` — 行内图片源数据（来自 EPUB media sidecar）
  - `InlineImagePlacement` — 排版后的行内图片位置
  - `InlineMarkerReservation` — 行内标记预留
  - `TextBlockDecoration` — 块级装饰（背景/边框/阴影/不透明度）
  - `TextRubyPlacement` — Ruby 注音位置

---

#### 1.2.4 EPUB V2 排版引擎 (engine/epub/)

**入口类：EpubTypesetterV2**

- **所在文件**：`feature/reader/engine/epub/EpubTypesetterV2.kt`
- **定位**：V2 版 EPUB 排版入口，基于 DOM + CSS 的真正盒树排版
- **排版流水线**：
  1. 样式表过滤（按本章 `<link>` 清单）
  2. `EpubStyleResolver` — CSS 级联计算
  3. `EpubBoxTreeBuilder` — 构建盒树（block/inline/float/table）
  4. `EpubBlockLayout` — 块级布局
  5. `EpubPageBuilder` — 分页构建

**核心类：**

| 类名 | 文件 | 职责 |
|------|------|------|
| `EpubTypesetterV2` | `EpubTypesetterV2.kt` | V2 排版入口，编排整个流水线 |
| `EpubBlockLayout` | `EpubBlockLayout.kt` | 块级布局引擎 |
| `EpubInlineLayout` | `EpubInlineLayout.kt` | 行内布局引擎 |
| `EpubBoxTreeBuilder` | `EpubBoxTree.kt` | 从 styled DOM 构建盒树 |
| `EpubBlockBox` / `EpubInlineFlowBox` / `EpubImageBox` / `EpubTableBox` | `EpubBoxTree.kt` | 各种盒节点 |
| `EpubPageBuilder` | `EpubPageBuilder.kt` | 将连续布局分页 |
| `EpubLayoutContext` | `EpubFlowModel.kt` | 排版上下文（spec/measure/bundle 等） |
| `FloatBand` / `BfcState` / `FlowCursor` / `FlowLine` / `FlowOutput` | `EpubFlowModel.kt` | 流式布局模型（浮动/ BFC / 行流） |

**其他 EPUB 相关类：**
- `EpubBoxLayoutBackend` — 旧版 EPUB 盒布局后端（legacy blocks 路径，基于 `EpubLayoutBlock`）
- `EpubThemeColors` — EPUB 主题色解析
- `ChapterStrip` — 章节条带（滚动模式用）

---

#### 1.2.5 其他 engine 核心类

| 类名 | 文件 | 职责 |
|------|------|------|
| `TextMeasure` (interface) | `TextMeasure.kt` | 文本测量接口（charWidths / breakLines / metrics） |
| `AndroidTextMeasure` | `AndroidTextMeasure.kt` | 基于 Android Paint 的文本测量实现 |
| `PageAnnotations` | `PageAnnotations.kt` | 页批注几何计算（高亮矩形、标记点） |
| `PageSelection` | `PageSelection.kt` | 文本选区处理（TextPos, SelectionRect, ReaderPageLink） |
| `EpubThemeColors` | `EpubThemeColors.kt` | EPUB 主题色计算 |

---

### 1.3 渲染层 (render/)

| 类名 | 文件 | 职责 |
|------|------|------|
| `PageBitmapRenderer` | `PageBitmapRenderer.kt` | 页面位图渲染器（将 TextPage 绘制到 Canvas） |
| `ReaderPageStyle` | `ReaderPageStyle.kt` | 页面样式（颜色/字体/间距等） |
| `AnnotationInk` (object) | `AnnotationInk.kt` | 批注墨迹样式工具 |
| `ReaderBackgroundProvider` | `ReaderBackgroundProvider.kt` | 阅读背景提供者 |

---

### 1.4 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `ReaderScreen` | `ReaderScreen.kt` | 阅读器主界面 |
| `CompanionChatScreen` | `CompanionChatScreen.kt` | 伴读聊天界面（在阅读器内） |

**Reader 模块内的纯 UI 组件（仅列名）：**

`ReaderPane`, `ReaderScrollPane`, `PageBitmapWindow`, `PageTurnCompositor`, `PageTurnDriver`, `PageFoldGeometry`, `ReaderChrome`, `ReaderTypographySheet`, `ReaderTypographyCard`, `ReaderTypographyControls`, `ReaderTypographyStepper`, `ReaderTypographyAdvanced`, `ReaderNavigationSheets`, `ReaderTableOfContents`, `ReaderSearch`, `ReaderAiSheet`, `ReaderBookDetail`, `ReaderCompanion`, `ReaderComposerBar`, `ReaderCustomThemeEditor`, `ReaderListenOrb`, `ReaderTextTools`, `ReaderTransientOverlays`, `AnnotationDiscussionSheet`, `BookTextSearch`, `CompanionChatActions`, `CompanionChatDialogs`, `CompanionChatHeader`, `CompanionChatList`, `CompanionChatTheme`, `CompanionCitation`, `CompanionComposer`, `CompanionMessageParts`, `CompanionOrb`, `CompanionProcessCard`, `CompanionToolPresentation`, `CompanionVoiceBubble`, `StreamingTicker`, `AiRichText`

---

## 2. feature/listen/ - 听书 / 有声书制作

听书播放页 + 有声书制作（角色提取、剧本编辑、批量生成）。

### 2.1 ViewModel 列表

#### 2.1.1 AudiobookProductionViewModel

- **所在文件**：`feature/listen/AudiobookProductionViewModel.kt`
- **核心 StateFlow**：
  - `uiState: MutableStateFlow<AudiobookProductionUiState>`
    - `book: BookEntity?` — 当前书籍
    - `chapters: List<ChapterEntity>` — 章节列表
    - `chapterStates: List<AudiobookChapterEntity>` — 各章节有声书状态
    - `startChapter / endChapter` — 制作范围
    - `estimate: AudiobookCostEstimate` — 成本估算
    - `isRunning: Boolean` — 是否正在制作
    - `progressText: String` / `progress: Float?` — 进度
    - `message: String?` — 提示消息
  - `events: Flow<AudiobookProductionEvent>`
    - `OpenScript(chapterIndex)` — 打开剧本编辑
- **关键 public 方法**：
  - `setStartChapter(index)` / `setEndChapter(index)` — 设置制作范围
  - `startProduction()` — 开始批量制作
  - `cancelProduction()` — 取消制作
  - `openScript(chapterIndex)` — 打开某章剧本

---

#### 2.1.2 AudiobookRoleViewModel

- **所在文件**：`feature/listen/AudiobookRoleViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<AudiobookRoleUiState>`
    - `book: BookEntity?`
    - `roles: List<AudiobookRoleEntity>` — 角色列表
    - `voices: List<TtsVoiceEntity>` — 可用音色
    - `isWorking: Boolean`
    - `message: String?`
    - `previewPath: String?` — 预览音频路径
- **关键 public 方法**：
  - `extract(useAi)` — 提取角色（AI 提取或手动）
  - `assignVoice(roleId, voiceId)` — 为角色分配音色
  - `renameRole(roleId, name)` — 重命名角色
  - `setRoleKind(roleId, kind)` — 设置角色类型（旁白/主角/配角）
  - `previewRole(roleId)` — 预览角色配音
  - `saveRoles()` — 保存角色配置

---

#### 2.1.3 AudiobookScriptViewModel

- **所在文件**：`feature/listen/AudiobookScriptViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<AudiobookScriptUiState>`
    - `book: BookEntity?`
    - `chapter: ChapterEntity?`
    - `body: String` — 章节正文
    - `roles: List<AudiobookRoleEntity>`
    - `segments: List<AudiobookSegmentEntity>` — 分段结果
    - `chapterState: AudiobookChapterEntity?`
    - `estimate: AudiobookCostEstimate`
    - `isWorking: Boolean`
    - `message: String?`
    - `previewPath: String?`
  - `events: Flow<AudiobookScriptEvent>`
    - `Confirmed` — 剧本确认
- **关键 public 方法**：
  - `analyzeWithAi()` — AI 分析剧本（自动分段+分配角色）
  - `updateSegment(segmentId, roleId, text)` — 修改分段
  - `mergeSegments(from, to)` — 合并分段
  - `splitSegment(segmentId, position)` — 拆分分段
  - `previewSegment(segmentId)` — 预览单段
  - `confirmAndGenerate()` — 确认并生成

---

#### 2.1.4 TtsTuningViewModel

- **所在文件**：`feature/listen/TtsTuningViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<TtsTuningUiState>`
    - `settings: TtsSettings` — TTS 设置
    - `bookCache: SpeechCacheBookStats?` — 本书缓存统计
- **关键 public 方法**：
  - `setEngineMode(mode)` — 引擎模式（系统/云端 AI）
  - `setAiVoice(voice)` — AI 音色
  - `setSystemRate/Pitch(speed)` — 系统 TTS 语速/音调
  - `setAiSpeed/Volume/Pitch(value)` — AI TTS 速度/音量/音调
  - `setAllowAudioMixing(value)` — 允许音频混音
  - `setTrimSilence(value)` — 修剪静音
  - `setGranularity(value)` — 合成粒度（句/段/章）
  - `setMaxChars / setConcurrency / setRetryCount / setPrefetchCount` — 高级参数
  - `clearBookCache()` — 清除本书语音缓存

---

### 2.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `ListenPlayerScreen` | `ListenPlayerScreen.kt` | 听书播放器主界面 |
| `AudiobookProductionScreen` | `AudiobookProductionScreen.kt` | 有声书制作（范围选择+进度） |
| `AudiobookRoleScreen` | `AudiobookRoleScreen.kt` | 角色配音管理 |
| `AudiobookScriptScreen` | `AudiobookScriptScreen.kt` | 剧本编辑与分段 |

**纯 UI 组件（仅列名）：**

`AudiobookPageShell`, `ListenChapterGrouping`

---

## 3. feature/importer/ - 导入功能

书籍导入（TXT / EPUB / 局域网传输 / 批量导入）。

### 3.1 ViewModel 列表

#### 3.1.1 ImportPickerViewModel

- **所在文件**：`feature/importer/ImportPickerViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<ImportPickerState>`
    - `scanning: Boolean` — 是否扫描中
    - `folderName: String` — 文件夹名
    - `files: List<ScannedBookFile>` — 扫描到的文件
    - `alreadyImported: Set<Uri>` — 已在书架中的文件
    - `selected: Set<Uri>` — 已选中的文件
    - `createGroupsFromFolders: Boolean` — 是否按文件夹创建分组
    - `searchQuery: String` — 搜索关键词
    - `error: String?` — 错误信息
- **关键 public 方法**：
  - `toggleSelection(uri)` — 切换选中
  - `selectAllVisible()` / `clearSelection()` — 全选/清空
  - `setCreateGroupsFromFolders(value)` — 设置按文件夹分组
  - `setSearchQuery(query)` — 设置搜索词
  - `importSelected()` — 导入选中的文件

---

#### 3.1.2 ImportPreviewViewModel

- **所在文件**：`feature/importer/ImportPreviewViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<ImportPreviewUiState>`
    - `preview: TxtImportPreview?` — 预览数据
    - `title / author` — 书名/作者
    - `customRegex: String` — 自定义分章正则
    - `isWorking: Boolean`
    - `progressMessage / progressFraction` — 导入进度
    - `aiRuleProposal: AiChapterRuleProposal?` — AI 建议的分章规则
    - `errorMessage: String?`
  - `events: Flow<ImportPreviewEvent>`
    - `Imported(bookId)` — 导入成功
- **关键 public 方法**：
  - `setTitle(value)` / `setAuthor(value)` / `setCustomRegex(value)` — 编辑元数据
  - `applyRule(ruleId)` — 应用某条分章规则
  - `proposeRuleWithAi()` — AI 生成分章规则
  - `startImport()` — 开始导入

---

#### 3.1.3 LanTransferViewModel

- **所在文件**：`feature/importer/LanTransferViewModel.kt`
- **核心 StateFlow**：
  - `state: StateFlow<LanServerState>` — 直接代理 `LanBookServer.state`
  - `events: Flow<LanTransferEvent>`
    - `Message(text)` — 提示消息
    - `Imported` — 导入完成
- **关键 public 方法**：
  - `start()` — 启动局域网接收服务
  - `stop()` — 停止服务
  - `discard(file)` — 丢弃已接收文件
  - `importAll()` — 全部导入

---

### 3.2 核心引擎/控制器类

| 类名 | 文件 | 类型 | 职责 |
|------|------|------|------|
| `ImportCoordinator` | `ImportCoordinator.kt` | 控制器 | 导入协调器，编排预览→导入流程 |
| `ImportSessionStore` | `ImportSessionStore.kt` | 存储 | 导入会话存储 |
| `BatchImportRequestStore` | `BatchImportRequestStore.kt` | 存储 | 批量导入请求存储 |
| `WorkBatchImportScheduler` | `WorkBatchImportScheduler.kt` | 调度器 | 基于 WorkManager 的批量导入调度 |
| `BatchImportWorker` | `BatchImportWorker.kt` | Worker | 批量导入后台任务 |
| `TxtImportWorker` | `TxtImportWorker.kt` | Worker | TXT 导入后台任务 |
| `BookTextMaterializeWorker` | `BookTextMaterializeWorker.kt` | Worker | 文本物化后台任务 |
| `BookEmbeddingWorker` | `BookEmbeddingWorker.kt` | Worker | 书籍嵌入后台任务 |

**TXT 导入相关：**

| 类名 | 文件 | 职责 |
|------|------|------|
| `TxtChapterSplitter` | `TxtChapterSplitter.kt` | TXT 章节分割器（多规则匹配+自定义正则） |
| `TxtTocRuleLoader` | `TxtTocRuleLoader.kt` | TXT 目录规则加载器 |
| `TxtMetadataDetector` (object) | `TxtMetadataDetector.kt` | TXT 元数据检测（书名/作者） |
| `TextEncodingDetector` | `TextEncodingDetector.kt` | 文本编码自动检测 |
| `AiChapterRuleAgent` | `AiChapterRuleAgent.kt` | AI 分章规则建议代理 |

**EPUB 导入相关：**

| 类名 | 文件 | 职责 |
|------|------|------|
| `EpubPackageInspector` | `EpubPackageInspector.kt` | EPUB 包结构检查器 |
| `EpubTextExtractor` | `EpubTextExtractor.kt` | EPUB 文本提取器 |
| `EpubLayoutDocumentParser` | `EpubLayoutDocumentParser.kt` | EPUB 布局文档解析器 |
| `EpubMetadataResolver` (object) | `EpubMetadataResolver.kt` | EPUB 元数据解析 |
| `EpubTocMapper` | `EpubTocMapper.kt` | EPUB 目录映射 |
| `EpubGenerator` | `EpubGenerator.kt` | EPUB 生成器（导出用？） |
| `EpubLegacyStyleBridge` | `EpubLegacyStyleBridge.kt` | EPUB 旧版样式桥接 |

**DI 模块：**
- `ImportModule` — Hilt 依赖注入模块

---

### 3.3 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `ImportPickerScreen` | `ImportPickerScreen.kt` | 导入文件选择器 |
| `ImportPreviewScreen` | `ImportPreviewScreen.kt` | 导入预览与配置 |
| `LanTransferScreen` | `LanTransferScreen.kt` | 局域网传输 |

---

## 4. feature/bookshelf/ - 书架

书架主页 + 分组/标签管理。

### 4.1 ViewModel 列表

#### 4.1.1 BookshelfViewModel

- **所在文件**：`feature/bookshelf/BookshelfViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<BookshelfUiState>`（通过 combine 构建）
    - `books: List<BookEntity>` — 书籍列表（受筛选影响）
    - `layout: ShelfLayout` — 布局（列表/网格）
    - `filter: ShelfFilter` — 筛选条件
    - `tags: List<BookTagEntity>` — 所有标签
    - `groups: List<ShelfGroupEntity>` — 所有分组
    - `groupCounts / tagCounts` — 分组/标签计数
    - `tagRefs: List<BookTagRefEntity>` — 书籍-标签关联
    - `totalBooks: Int` — 未筛选的书籍总数
    - `recentBook: BookEntity?` — 最近在读的书
    - `recentChapterTitle: String` — 最近在读章节名
    - `isImporting: Boolean` — 是否正在导入
    - `selectionActive: Boolean` / `selectedBookIds: Set<Long>` — 选择模式
  - `events: Flow<BookshelfEvent>`
    - `OpenImportPreview(sessionId)` — 打开导入预览
    - `OpenBook(bookId)` — 打开书籍
    - `ShowMessage(message)` — 提示消息
- **关键 public 方法**：
  - `openBook(bookId)` — 打开书籍
  - `setFilter(filter)` / `toggleTag(tagId)` / `setGroup(groupId)` — 筛选
  - `toggleSelectionMode()` / `toggleBookSelection(bookId)` — 选择模式
  - `deleteSelected()` — 删除选中书籍
  - `moveSelectedToGroup(groupId)` — 移动到分组
  - `addTagToSelected(tagId)` / `removeTagFromSelected(tagId)` — 批量打标签
  - `importFromUris(uris)` — 从 URI 导入
  - `togglePin(bookId)` — 切换置顶

---

#### 4.1.2 ShelfManageViewModel

- **所在文件**：`feature/bookshelf/manage/ShelfManageViewModel.kt`
- **核心 StateFlow**：
  - `state: StateFlow<ShelfManageUiState>`
    - `groups: List<ShelfGroupEntity>` — 分组列表
    - `groupCounts: Map<Long?, Int>` — 分组计数
    - `tags: List<BookTagEntity>` — 标签列表
    - `tagCounts: Map<Long, Int>` — 标签计数
    - `selectedTagIds: Set<Long>` — 选中的标签 ID
  - `events: Flow<ShelfManageEvent>`
    - `Message(text)` — 提示消息
- **关键 public 方法**：
  - `saveGroup(name, parentId, existing)` — 保存分组
  - `deleteGroup(groupId)` — 删除分组
  - `reorderGroups(groups)` — 重排分组
  - `saveTag(name)` — 保存标签
  - `deleteTag(tagId)` — 删除标签
  - `mergeTags(fromIds, intoId)` — 合并标签
  - `exportTagsJson()` / `importTagsJson(json)` — 标签导入导出
  - `toggleTagSelection(tagId)` — 切换标签选中

---

### 4.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `BookshelfScreen` | `BookshelfScreen.kt` | 书架主界面 |
| `ShelfGroupScreen` | `manage/ShelfGroupScreen.kt` | 分组管理 |
| `TagManageScreen` | `manage/TagManageScreen.kt` | 标签管理 |

**纯 UI 组件（仅列名）：**

`BookLongPressOverlay`, `ShelfFilter`, `ShelfOrganizationComponents`

---

## 5. feature/settings/ - 设置页

设置模块包含 15 个 ViewModel，按功能分为：主设置、AI 服务、TTS、图像生成、外观、备份、字体库、图片库、模块管理等。

### 5.1 ViewModel 列表

#### 5.1.1 SettingsViewModel **[主设置]**

- **所在文件**：`feature/settings/SettingsViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<SettingsUiState>`
    - `providers: List<AiProviderEntity>` — AI Provider 列表
    - `models: List<AiModelEntity>` — 所有模型
    - `assignments: Map<ModelRole, Long?>` — 角色→模型分配
    - `embeddingProgress: LibraryEmbeddingProgress` — 嵌入进度
    - `appearance: AppearanceSettings` — 外观设置
    - `shelfLayout: ShelfLayout` — 书架布局
    - `suggestionRepliesEnabled` — 回复建议
    - `memory: CompanionMemorySettings` — 记忆设置
    - `showAiAnnotations` — 显示 AI 批注
    - `multiBubbleEnabled` — 多气泡回复
    - `autonomy: CompanionAutonomySettings` — Agent 主动调用开关
    - `coverCacheBytes / bookStorageBytes` — 存储占用
  - `events: Flow<SettingsEvent>`
    - `ShowMessage(message)` — 提示消息
- **关键 public 方法**：
  - `assignModel(role, modelId)` — 分配模型到角色
  - `retryEmbedding()` / `rebuildEmbedding()` — 嵌入管理
  - `setThemeMode(mode)` / `setAccentPreset(preset)` / `setCustomAccent(argb)` — 外观
  - `setShelfLayout(layout)` — 书架布局
  - `setSuggestionReplies(enabled)` — 回复建议
  - `setLongTermMemory(enabled)` / `setCrossBookMemory(enabled)` — 记忆设置
  - `setShowAiAnnotations(enabled)` — AI 批注显示
  - `setMultiBubble(enabled)` — 多气泡
  - `setVoiceReplies(enabled)` / `setImageReplies(enabled)` — 语音/图片回复
  - `setProactiveAnnotations(enabled)` 等主动能力开关
  - `refreshStorageUsage()` / `clearCoverCache()` — 存储管理

---

#### 5.1.2 ProviderDetailViewModel

- **所在文件**：`feature/settings/ProviderDetailViewModel.kt`
- **核心 StateFlow**：`uiState`（Provider 详情+模型列表+测试状态）
- **关键 public 方法**：
  - `save(draft)` — 保存 Provider
  - `delete()` — 删除 Provider
  - `test()` — 测试连接
  - `saveModel(draft)` / `removeModel(model)` — 模型管理
  - `fetchModelCatalog()` — 获取模型目录
  - `confirmCatalogPick(selected)` / `dismissCatalogPick()` — 模型目录选择

---

#### 5.1.3 TtsSettingsViewModel

- **所在文件**：`feature/settings/TtsSettingsViewModel.kt`
- **核心 StateFlow**：`uiState`（TTS 设置+预览状态）
- **关键 public 方法**：
  - `setEngineMode(mode)` — 系统/AI 引擎
  - `setSystemEngine/Package/Language/Rate/Pitch(...)` — 系统 TTS
  - `setAiVoice/Speed/Volume/Pitch(...)` — AI TTS
  - `setAllowAudioMixing / setTrimSilence / setSynthesisGranularity(...)`
  - `setMaxSynthesisChars / setSynthesisConcurrency / setRetryCount / setPrefetchCount(...)`
  - `setAiProvider/BaseUrl/GroupId/Model(...)` — AI 提供商配置
  - `saveApiKey(raw)` / `clearApiKey()` — API Key 管理
  - `preview()` — 试听预览

---

#### 5.1.4 ImageGenSettingsViewModel

- **所在文件**：`feature/settings/ImageGenSettingsViewModel.kt`
- **核心 StateFlow**：`uiState`（图像生成 API 设置+测试状态）
- **关键 public 方法**：
  - `setProvider(provider)` — 选择 API 提供商
  - `setBaseUrl / setModel / setSize / setSampler / setSteps / setScale(...)`
  - `setPositivePrompt / setNegativePrompt(...)`
  - `saveApiKey(raw)` / `clearApiKey()`
  - `testGenerate()` — 测试生成

---

#### 5.1.5 BackupSettingsViewModel

- **所在文件**：`feature/settings/BackupSettingsViewModel.kt`
- **核心 StateFlow**：`uiState`（备份设置+状态）
- **关键 public 方法**：
  - `save(settings, password)` — 保存备份设置
  - `clearPassword()` — 清除密码
  - `exportBackup(uri)` — 导出备份
  - `importBackup(uri)` — 导入备份

---

#### 5.1.6 FontLibraryViewModel

- **所在文件**：`feature/settings/FontLibraryViewModel.kt`
- **核心 StateFlow**：`uiState`（字体列表+导入状态）
- **关键 public 方法**：
  - `prepareImport(uri)` — 准备导入字体
  - `confirmImport(pending, displayName)` — 确认导入
  - `cancelImport(pending)` — 取消导入
  - `selectFont(fontId)` — 选择字体
  - `rename(fontId, displayName)` — 重命名字体
  - `delete(font)` — 删除字体

---

#### 5.1.7 ImageLibraryViewModel

- **所在文件**：`feature/settings/ImageLibraryViewModel.kt`
- **核心 StateFlow**：`uiState`（图片列表+导入状态）
- **关键 public 方法**：
  - `prepareImport(uri)` — 准备导入图片
  - `confirmImport(pending, displayName)` — 确认导入
  - `cancelImport(pending)` — 取消导入
  - `selectForBackground(imageId)` — 设为阅读背景
  - `rename(imageId, displayName)` — 重命名
  - `delete(image)` — 删除
  - `clearBackground()` — 清除背景

---

#### 5.1.8 其他 Settings ViewModel（简）

| ViewModel | 文件 | 核心职责 |
|-----------|------|----------|
| `GlobalPresetSettingsViewModel` | `GlobalPresetSettingsViewModel.kt` | 全局阅读预设管理 |
| `ModuleSettingsViewModel` | `ModuleSettingsViewModel.kt` | 功能模块开关 |
| `SpeechCacheViewModel` | `SpeechCacheViewModel.kt` | 语音缓存管理 |
| `WebSearchSettingsViewModel` | `WebSearchSettingsViewModel.kt` | 网页搜索配置 |
| `UserMaskSettingsViewModel` | `UserMaskSettingsViewModel.kt` | 用户面具（头像）管理 |
| `ApiLogViewModel` | `ApiLogViewModel.kt` | API 调用日志查看 |
| `AppUpdateViewModel` | `AppUpdateViewModel.kt` | 应用更新检查 |
| `TtsVoiceLibraryViewModel` | `TtsVoiceLibraryScreen.kt` | TTS 音色库管理 |

---

### 5.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `SettingsScreen` | `SettingsScreen.kt` | 设置主页（含 4 个子屏） |
| `AiAndCompanionSettingsScreen` | `SettingsScreen.kt` | AI 与伴读设置 |
| `ReadingAppearanceSettingsScreen` | `SettingsScreen.kt` | 阅读外观设置 |
| `DataSettingsScreen` | `SettingsScreen.kt` | 数据与存储设置 |
| `AboutSettingsScreen` | `SettingsScreen.kt` | 关于页 |
| `ProviderDetailScreen` | `ProviderDetailScreen.kt` | Provider 详情 |
| `AiServiceScreen` | `AiServiceScreen.kt` | AI 服务总览 |
| `TtsSettingsScreen` | `TtsSettingsScreen.kt` | TTS 设置 |
| `TtsVoiceLibraryScreen` | `TtsVoiceLibraryScreen.kt` | TTS 音色库 |
| `ImageGenSettingsScreen` | `ImageGenSettingsScreen.kt` | 图像生成设置 |
| `BackupSettingsScreen` | `BackupSettingsScreen.kt` | 备份与恢复 |
| `FontLibraryScreen` | `FontLibraryScreen.kt` | 字体库 |
| `ImageLibraryScreen` | `ImageLibraryScreen.kt` | 图片库 |
| `GlobalPresetSettingsScreen` | `GlobalPresetSettingsScreen.kt` | 全局预设 |
| `ModuleSettingsScreen` | `ModuleSettingsScreen.kt` | 模块开关 |
| `SpeechCacheScreen` | `SpeechCacheScreen.kt` | 语音缓存 |
| `WebSearchSettingsScreen` | `WebSearchSettingsScreen.kt` | 网页搜索设置 |
| `UserMaskSettingsScreen` | `UserMaskSettingsScreen.kt` | 用户面具设置 |
| `ApiLogScreen` | `ApiLogScreen.kt` | API 日志 |

**纯 UI 组件（仅列名）：**

`SettingsWidgets`, `AppUpdateUi`, `ProviderLabels`

---

## 6. feature/companion/ - 伴读角色

伴读角色管理 + 角色编辑 + 角色记忆。

### 6.1 ViewModel 列表

#### 6.1.1 CompanionViewModel

- **所在文件**：`feature/companion/CompanionViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<CompanionUiState>`
    - `personas: List<PersonaEntity>` — 角色列表
    - `activePersonaId: Long?` — 当前激活角色
    - `memoryCounts: Map<Long, Long>` — 各角色长期记忆条数
    - `longTermMemoryEnabled: Boolean` — 全局长期记忆开关
    - `loaded: Boolean` — 是否加载完成
- **关键 public 方法**：
  - `selectPersona(personaId)` — 切换激活角色
  - `createPersona()` — 新建角色
  - `deletePersona(personaId)` — 删除角色
  - `duplicatePersona(personaId)` — 复制角色

---

#### 6.1.2 PersonaEditorViewModel

- **所在文件**：`feature/companion/PersonaEditorViewModel.kt`
- **核心 StateFlow**：
  - `state: StateFlow<PersonaEditorState>`
    - `personaId / name / subtitle` — 角色基本信息
    - `personality / speakingStyle / greeting` — 性格/说话风格/问候语
    - `dialogs: List<PersonaExampleDialog>` — 示例对话
    - `worldBook: List<PersonaLoreEntry>` — 世界书/知识库
    - `enabledTools: Set<String>` — 启用的工具
    - `appearance: PersonaChatAppearance` — 聊天外观
    - `avatarAssetId / voiceId` — 头像/音色
    - `isWorking / errorMessage` — 工作状态
- **关键 public 方法**：
  - `setName / setSubtitle / setPersonality / setSpeakingStyle / setGreeting(...)` — 基本信息编辑
  - `addExampleDialog() / updateExampleDialog(...) / removeExampleDialog(id)` — 示例对话
  - `addLoreEntry(...) / updateLoreEntry(...) / removeLoreEntry(id)` — 世界书条目
  - `toggleTool(toolName)` — 工具开关
  - `setAppearance(appearance)` — 外观设置
  - `importFromCard(uri)` — 从 SillyTavern 角色卡导入
  - `save()` — 保存角色
  - `generateAvatar(prompt)` — AI 生成头像
  - `testVoice(text)` — 试听音色

---

#### 6.1.3 PersonaMemoryViewModel

- **所在文件**：`feature/companion/PersonaMemoryViewModel.kt`
- **核心 StateFlow**：
  - `state: StateFlow<PersonaMemoryState>`
    - `personaName: String` — 角色名
    - `total: Long` — 记忆总数
    - `memories: List<StoredMemory>` — 记忆列表
    - `bookTitles: Map<Long, String>` — 书籍 ID→书名映射
    - `query: String` — 搜索关键词
    - `profile: String` — 角色画像摘要
    - `loading / loadingMore` — 加载状态
  - `events: Flow<PersonaMemoryEvent>`
    - `Message(text)` — 提示消息
- **关键 public 方法**：
  - `refresh()` — 刷新记忆列表
  - `loadMore()` — 加载更多
  - `setQuery(query)` — 搜索记忆
  - `deleteMemory(memoryId)` — 删除记忆
  - `clearAll()` — 清空全部记忆
  - `updateProfile(text)` — 更新角色画像

---

### 6.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `CompanionScreen` | `CompanionScreen.kt` | 伴读角色主页 |
| `PersonaEditorScreen` | `PersonaEditorScreen.kt` | 角色编辑器 |
| `PersonaMemoryScreen` | `PersonaMemoryScreen.kt` | 角色记忆管理 |

**纯 UI 组件（仅列名）：**

`PersonaAppearanceCards`

---

## 7. feature/bookdetail/ - 书籍详情

### 7.1 ViewModel

#### BookDetailViewModel

- **所在文件**：`feature/bookdetail/BookDetailViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<BookDetailUiState>`
    - `book: BookEntity?` — 书籍信息
    - `chapters: List<ChapterEntity>` — 章节列表
    - `bookmarks: List<BookmarkEntity>` — 书签
    - `notes: List<NoteEntity>` — 笔记
    - `annotations: List<AnnotationEntity>` — 批注
    - `illustrations: List<IllustrationEntity>` — 插图
    - `personaNames: Map<Long, String>` — 角色 ID→名映射
    - `totalDurationMs / readingDays / streakDays` — 阅读统计
    - `durationsByEpochDay: Map<Long, Long>` — 每日阅读时长
    - `imageLibrary: List<ReaderImageAsset>` — 图片库
    - `shelfGroups / shelfTags / shelfTagRefs` — 分组标签信息
    - `audiobookReadyChapters / audiobookTotalMillis / audiobookRoleNames` — 有声书状态
    - `embeddingProgress: BookEmbeddingProgress?` — 嵌入进度
    - `description: String` — 书籍描述
    - `isLoading / isWorking` — 加载/工作状态
- **关键 public 方法**（推断）：
  - `startReading()` — 开始阅读
  - `toggleFavorite()` — 切换收藏
  - `updateBookGroup(groupId)` — 修改分组
  - `toggleBookTag(tagId)` — 切换标签
  - `generateCover(prompt)` — AI 生成封面
  - `searchOnlineCover()` — 在线搜索封面
  - `exportNotes(uri)` — 导出笔记
  - `deleteBook()` — 删除书籍
  - `reidentifyChapters()` — 重新识别章节

---

### 7.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `BookDetailScreen` | `BookDetailScreen.kt` | 书籍详情页 |

**纯 UI 组件（仅列名）：**

`BookDetailCover`, `BookDetailMetadata`, `BookDetailContent`, `BookDescriptionExtractor`, `BookDetailAssets`

---

## 8. feature/stats/ - 阅读统计

### 8.1 ViewModel

#### StatsViewModel

- **所在文件**：`feature/stats/StatsViewModel.kt`
- **核心 StateFlow**：
  - `uiState: StateFlow<StatsUiState>`
    - `period: StatsPeriod` — 统计周期（日/周/月/年）
    - `anchorDate: LocalDate` — 锚定日期
    - `periodLabel: String` — 周期显示文案
    - `canGoNext: Boolean` — 是否可前进到下一周期
    - `periodDurationMs: Long` — 本周期阅读总时长
    - `previousPeriodDurationMs: Long` — 上一周期总时长
    - `streakDays: Int` — 当前连续阅读天数
    - `longestStreakDays: Int` — 最长连续天数
    - `periodReadingDays: Int` — 本周期阅读天数
    - `finishedBooks: Int` — 读完的书籍数
    - `bookmarkNoteCount: Int` — 笔记+段落批注总量
    - `aiChatCount: Int` — AI 对话总数
    - `durationsByEpochDay: Map<Long, Long>` — 每日阅读时长
    - `topBooks: List<PeriodBookStat>` — 本周期读得最多的书
- **关键 public 方法**：
  - `setPeriod(period)` — 切换统计周期
  - `goPrev()` / `goNext()` — 上一/下一周期
  - `goToToday()` — 回到今天

---

### 8.2 Screen 级 Composable

| 组件名 | 文件 | 说明 |
|--------|------|------|
| `StatsScreen` | `StatsScreen.kt` | 阅读统计页 |

---

## 9. ViewModel 总索引表

| # | ViewModel 名称 | 所属模块 | 所在文件 | 核心职责 |
|---|---------------|----------|----------|----------|
| 1 | `ReaderViewModel` | reader | `reader/ReaderViewModel.kt` | 阅读器主界面：阅读位置、书签、批注、排版设置、阅读统计 |
| 2 | `ReaderSearchViewModel` | reader | `reader/ReaderSearchViewModel.kt` | 书内关键词搜索 |
| 3 | `ReaderCompanionViewModel` | reader | `reader/ReaderCompanionViewModel.kt` | 阅读器内伴读聊天（Agent 循环+工具调用） |
| 4 | `ReaderAiViewModel` | reader | `reader/ReaderAiViewModel.kt` | 选段 AI 操作（解释/翻译/总结等） |
| 5 | `ReaderListenViewModel` | reader | `reader/ReaderListenViewModel.kt` | 阅读页听书门面（代理 ListenEngine） |
| 6 | `ReaderSelectionMediaViewModel` | reader | `reader/ReaderSelectionMediaViewModel.kt` | 选区 TTS 朗读 + AI 生图 |
| 7 | `AnnotationDiscussionViewModel` | reader | `reader/AnnotationDiscussionViewModel.kt` | 批注讨论串（用户回复+AI 应答） |
| 8 | `AudiobookProductionViewModel` | listen | `listen/AudiobookProductionViewModel.kt` | 有声书批量制作（范围+进度+成本估算） |
| 9 | `AudiobookRoleViewModel` | listen | `listen/AudiobookRoleViewModel.kt` | 角色提取与音色分配 |
| 10 | `AudiobookScriptViewModel` | listen | `listen/AudiobookScriptViewModel.kt` | 剧本编辑（分段+角色分配+预览） |
| 11 | `TtsTuningViewModel` | listen | `listen/TtsTuningViewModel.kt` | TTS 参数调优（听书页内） |
| 12 | `ImportPickerViewModel` | importer | `importer/ImportPickerViewModel.kt` | 导入文件选择（文件夹扫描+多选） |
| 13 | `ImportPreviewViewModel` | importer | `importer/ImportPreviewViewModel.kt` | 导入预览（分章规则+元数据+AI 建议） |
| 14 | `LanTransferViewModel` | importer | `importer/LanTransferViewModel.kt` | 局域网传输接收 |
| 15 | `BookshelfViewModel` | bookshelf | `bookshelf/BookshelfViewModel.kt` | 书架主页（书籍列表+筛选+选择模式） |
| 16 | `ShelfManageViewModel` | bookshelf | `bookshelf/manage/ShelfManageViewModel.kt` | 分组与标签管理 |
| 17 | `SettingsViewModel` | settings | `settings/SettingsViewModel.kt` | 设置主页（模型分配+外观+存储+伴读设置） |
| 18 | `ProviderDetailViewModel` | settings | `settings/ProviderDetailViewModel.kt` | AI Provider 详情与模型管理 |
| 19 | `TtsSettingsViewModel` | settings | `settings/TtsSettingsViewModel.kt` | TTS 全局设置 |
| 20 | `ImageGenSettingsViewModel` | settings | `settings/ImageGenSettingsViewModel.kt` | 图像生成 API 设置 |
| 21 | `BackupSettingsViewModel` | settings | `settings/BackupSettingsViewModel.kt` | 备份与恢复 |
| 22 | `FontLibraryViewModel` | settings | `settings/FontLibraryViewModel.kt` | 字体库管理 |
| 23 | `ImageLibraryViewModel` | settings | `settings/ImageLibraryViewModel.kt` | 图片库管理 |
| 24 | `GlobalPresetSettingsViewModel` | settings | `settings/GlobalPresetSettingsViewModel.kt` | 全局阅读预设 |
| 25 | `ModuleSettingsViewModel` | settings | `settings/ModuleSettingsViewModel.kt` | 功能模块开关 |
| 26 | `SpeechCacheViewModel` | settings | `settings/SpeechCacheViewModel.kt` | 语音缓存管理 |
| 27 | `WebSearchSettingsViewModel` | settings | `settings/WebSearchSettingsViewModel.kt` | 网页搜索配置 |
| 28 | `UserMaskSettingsViewModel` | settings | `settings/UserMaskSettingsViewModel.kt` | 用户面具/头像 |
| 29 | `ApiLogViewModel` | settings | `settings/ApiLogViewModel.kt` | API 调用日志 |
| 30 | `AppUpdateViewModel` | settings | `settings/AppUpdateViewModel.kt` | 应用更新 |
| 31 | `TtsVoiceLibraryViewModel` | settings | `settings/TtsVoiceLibraryScreen.kt` | TTS 音色库 |
| 32 | `CompanionViewModel` | companion | `companion/CompanionViewModel.kt` | 伴读角色列表与激活切换 |
| 33 | `PersonaEditorViewModel` | companion | `companion/PersonaEditorViewModel.kt` | 角色编辑器（性格/外观/工具/世界书） |
| 34 | `PersonaMemoryViewModel` | companion | `companion/PersonaMemoryViewModel.kt` | 角色长期记忆管理 |
| 35 | `BookDetailViewModel` | bookdetail | `bookdetail/BookDetailViewModel.kt` | 书籍详情（统计+书签+笔记+批注+有声书） |
| 36 | `StatsViewModel` | stats | `stats/StatsViewModel.kt` | 阅读统计（日/周/月/年维度） |

**合计：36 个 ViewModel**

---

> 文档生成时间：2026-09-05
> 扫描目录：`/data/user/work/MoRead-module/app/src/main/java/com/mozhi/reader/feature/`
