# MoRead Core 模块 API 参考

> 扫描目录：`app/src/main/java/com/mozhi/reader/core/`
> 共计约 100 个 Kotlin/Java 文件，涵盖书籍库、语音、设置存储、数据库、备份、导入、向量数据库等核心能力。

---

## 目录总览

| 目录 | 文件数 | 功能领域 |
|------|--------|----------|
| `core/library/` | 16 | 书籍库核心：书籍/章节/批注/笔记/有声书/插图/书架/封面/文本/布局/媒体存储 |
| `core/speech/` | 8 | 语音/TTS：系统 TTS 封装、句子切分、语音缓存、定时停止、TTS 设置与音色仓库 |
| `core/datastore/` | 16 | 设置存储：阅读设置、主题、字体/图片库、文本替换规则、语法高亮、伴读设置、嵌入设置 |
| `core/database/` | 18 | Room 数据库：实体、DAO、迁移、类型转换、种子数据 |
| `core/backup/` | 5 | 备份恢复：WebDAV 客户端、备份归档管理、备份设置、自动备份 Worker |
| `core/importer/` | 9 | 书籍导入：导入网关、文件夹扫描、批量导入调度、局域网传输 |
| `core/vector/` | 5 | 向量数据库：ObjectBox 封装、切片/记忆实体、向量查询、分块器、嵌入规整 |
| `core/di/` | 4 | 依赖注入模块：Storage/Network/Vector/Coroutine |
| `core/diag/` | 3 | API 诊断日志 |
| `core/security/` | 1 | 加密 API Key 存储 |
| `core/retrieval/` | 2 | 检索管线：混合检索（向量+词法）、RRF 融合、BM25、阅读防剧透范围 |
| `core/epub/` | 9 | EPUB 解析：CSS 解析器、DOM 模型、样式解析器 |
| `core/readium/` | 1 | Readium 服务封装 |
| `core/update/` | 3 | 应用更新 |
| `core/media/` | 1 | 图片 API 设置 |

---

## 一、core/library/ — 书籍库

### 1.1 LibraryRepository.kt

**类/接口/object：**
- `data class ChapterDraft(index, title, href, charCount)` — 章节草稿（导入期）
- `data class BookTocEntryDraft(orderIndex, title, href, depth, parentOrderIndex, chapterIndex, hasChildren)` — 目录条目草稿
- `data class EditableChapterDraft(index, title, href, body)` — 可编辑章节草稿（用于章节重识别）
- `@Singleton class LibraryRepository(context, database, bookDao, textStore, textWriter, mediaStore, layoutStore, vectorStore, hookRegistry)` — 书籍库核心仓库

**public 方法摘要：**
- `observeBooks(): Flow<List<BookEntity>>` — 观察全部书籍
- `observeBook(bookId): Flow<BookEntity?>` — 观察单本书
- `observeChapters(bookId): Flow<List<ChapterEntity>>` — 观察章节列表
- `observeTocEntries(bookId): Flow<List<BookTocEntryEntity>>` — 观察目录
- `observeBookmarks(bookId): Flow<List<BookmarkEntity>>` — 观察书签
- `observeReadingDays(bookId): Flow<List<ReadingDailyEntity>>` — 观察阅读统计
- `getBooks/getBook/getChapters/getChapter/getTocEntries/getBookmarks/getReadingDays/getTagNames` — 一次性读取
- `insertBook(book, chapters, tocEntries): Long` — 插入书籍（事务）
- `saveProgress(bookId, locatorJson, chapterIndex, charOffset)` — 保存阅读进度
- `materializeBookText(bookId, chapters, markReady)` — 将章节正文写入 text.mz 并记录字节范围
- `readChapterText(bookId, chapter): String` — 读取单章正文（走 hook）
- `replaceChapterText(bookId, chapterIndex, range, replacement): Int` — 替换章节内文本
- `applyTextReplacementRules(bookId, rules): Int` — 应用正文替换规则
- `replaceBookChapters(bookId, chapters)` — 整书替换章节表和正文
- `addBookmark(bookId, ...): Long` — 添加书签（支持 locator 或 章内偏移）
- `deleteBookmark/updateBookmarkPosition` — 书签管理
- `recordReadingDuration(bookId, durationMs, recordedAt)` — 记录阅读时长（自动跨天分段）
- `deleteBook(book)` — 删除书籍及关联资源
- `updateBookMetadata/setReadState/setPinned/replaceBookCover/clearReExtractableCovers` — 书籍元数据管理
- `getEpubBooksMissingCovers/getEpubBooksMissingToc` — 查询缺失封面/目录的 EPUB

**功能描述：** 书籍库的核心入口类，聚合了书籍、章节、目录、书签、阅读统计的 CRUD，以及正文文本的读写、文本替换、章节重识别等高级操作。删书时同时清理向量、文本、媒体、布局、插图等所有关联资源。

---

### 1.2 AnnotationRepository.kt

**类/接口/object：**
- `@Singleton class AnnotationRepository(annotationDao)` — 批注仓库

**public 方法摘要：**
- `observeForBook(bookId): Flow<List<AnnotationEntity>>` — 观察书籍批注
- `observeCountForBook(bookId): Flow<Int>` — 观察批注计数
- `getForChapter/getForChapterRange/getCountForBook/getCountForChapter` — 按章/按范围查询
- `getReplyCounts(annotationIds): Map<Long, Int>` — 批量获取回复数
- `add(bookId, personaId, chapterIndex, startCharOffset, endCharOffset, selectedText, note, colorTag, style, mediaJson, ...): Long` — 添加批注
- `updateContent/updateStyle/updateNote` — 更新批注内容/样式/想法
- `delete(annotationId)` — 删除批注
- `observeReplies(annotationIds): Flow<List<AnnotationReplyEntity>>` — 观察讨论串回复
- `addReply(annotationId, personaId, contentMarkdown, replyToId, mediaJson): Long` — 添加回复
- `deleteReply(replyId)` — 删除回复

**功能描述：** 批注（高亮/划线/想法）的 CRUD 统一入口，用户批注与 AI 批注共用同一套表（通过 personaId 区分）。支持讨论串模式（楼主层 + 回复层）。选区坐标为章内 UTF-16 字符偏移。

---

### 1.3 NoteRepository.kt

**类/接口/object：**
- `@Singleton class NoteRepository(noteDao)` — 读书笔记仓库

**public 方法摘要：**
- `observeAll/observeForBook/observeCountForBook` — 观察笔记
- `getNote/getForBook/latestByKind` — 查询笔记
- `create(bookId, personaId, title, contentMarkdown, kind, ...): Long` — 创建笔记
- `updateContent/updateContentAndPosition` — 更新笔记内容/位置
- `delete(noteId)` — 删除笔记
- 常量：`KIND_NOTE = "NOTE"`, `KIND_PLOT_SUMMARY = "PLOT_SUMMARY"`

**功能描述：** 读书笔记的 CRUD，支持普通笔记和剧情梗概两种类型。personaId 为 null 表示用户手写笔记。

---

### 1.4 AudiobookRepository.kt

**类/接口/object：**
- `enum class AudiobookChapterState { NONE, SCRIPTED, CONFIRMED, SYNTHESIZING, READY, STALE }` — 有声书章节状态
- `enum class AudiobookRoleKind { NARRATOR, CHARACTER }` — 角色类型
- `enum class AudiobookEngine { SYSTEM, AI }` — 有声书引擎
- `@Singleton class AudiobookRepository(database, dao)` — 有声书仓库
- `enum class AudiobookEnginePolicy { ALL_SYSTEM, NARRATOR_SYSTEM_CHARACTERS_AI, ALL_AI, CUSTOM }` — 引擎分配策略

**public 方法摘要：**
- `observeRoles/observeSegments/observeChapters` — 观察角色/分段/章节
- `getRoles/getSegments/getChapter/getChapters/readyChapterCount` — 查询
- `replaceRoles/updateRole/addRole/deleteRole` — 角色管理
- `applyEnginePolicy(bookId, policy)` — 批量应用引擎策略
- `replaceScript(bookId, chapterIndex, revision, segments)` — 替换剧本
- `confirmScript(bookId, chapterIndex)` — 确认剧本
- `updateSegment/updateProducedSegment/updateChapter` — 更新分段/章节
- `markStale(bookId, chapterIndex)` — 标记章节失效

**功能描述：** 有声书（AI 多角色有声书）的数据管理，包括角色分配、剧本分段、合成状态追踪。支持按角色类型（旁白/角色）分配不同引擎（系统 TTS / AI TTS）。

---

### 1.5 BookCoverStore.kt

**类/接口/object：**
- `@Singleton class BookCoverStore(context)` — 书籍封面存储

**public 方法摘要：**
- `save(bookId, source): File` — 从 Uri 保存封面（压缩后存入应用私有目录）

**功能描述：** 将用户从相册选择的图片压缩后存进应用私有目录作为书籍封面。长边限制 1800px，有 alpha 走 PNG 否则 JPEG q90。文件名带随机后缀避免 Coil 缓存问题。

---

### 1.6 BookTextStore.kt

**类/接口/object：**
- `@Singleton class BookTextStore(context)` — 书籍正文文本读取存储

**public 方法摘要：**
- `textFile(bookId): File` — 获取 text.mz 文件路径
- `hasText(bookId): Boolean` — 判断是否已有正文
- `readChapter(bookId, byteOffset, byteLength): String` — 按字节范围读取单章正文（带 LRU 缓存）
- `delete(bookId)` — 删除整书正文
- `invalidate(bookId)` — 失效缓存

**功能描述：** 从每本书的 `text.mz` 二进制文件中按字节范围读取章节正文。单文件设计使删书只需一次目录删除，读取只需一次 seek。内置 3 条的 LRU 缓存。

---

### 1.7 BookTextWriter.kt

**类/接口/object：**
- `data class ChapterTextRange(index, byteOffset, byteLength, charCount)` — 章节文本字节范围
- `data class ChapterTextInput(index, body)` — 章节文本输入
- `@Singleton class BookTextWriter()` — 书籍正文写入器

**public 方法摘要：**
- `write(target, chapters): List<ChapterTextRange>` — 将多章正文写入 UTF-8 blob，返回字节范围
- `normalize(body): String` — 正文规范化（换行统一、去首全角空格、合并空行等）

**功能描述：** 将整本书的所有章节正文写入一个 UTF-8 blob 文件，并返回每个章节的字节偏移和字符数。写入时执行文本规范化（去首空格、统一换行、合并空行），保证阅读引擎无需防御源文件格式问题。

---

### 1.8 BookMediaStore.kt

**类/接口/object：**
- `data class BookImageInput(chapterIndex, charOffset, sourceName, altText, bytes)` — 导入期图片输入
- `data class BookInlineImage(chapterIndex, charOffset, imagePath, pixelWidth, pixelHeight, altText)` — 阅读器消费的行内图片
- `@Singleton class BookMediaStore(context)` — 书籍媒体存储

**public 方法摘要：**
- `replace(bookId, images)` — 批量替换书籍行内图片
- `read(bookId): List<BookInlineImage>` — 读取书籍全部行内图片
- `delete(bookId)` — 删除书籍媒体

**功能描述：** EPUB 行内图片的 sidecar 存储。正文仍只有 text.mz，每张图片在正文中用「［图片］」token 占位，sidecar 通过字符偏移定位原图。支持 PNG/JPEG/GIF/WEBP/SVG（SVG 渲染为 PNG）。

---

### 1.9 BookLayoutStore.kt

**类/接口/object：**
- `@Singleton class BookLayoutStore(context)` — EPUB 布局存储

**public 方法摘要：**
- `replace(bookId, epubFile, layoutPackage, chapters)` — 写入整书布局
- `readChapter(bookId, chapterIndex): EpubLayoutChapterBundle?` — 读取单章布局（含资源路径、字体、样式表）
- `hasCurrentLayout(bookId, expectedTextLengths): Boolean` — 校验布局完整性
- `delete(bookId)` — 删除布局

**功能描述：** EPUB 排版布局的持久化与读取。布局包括 DOM 结构、样式表、字体、资源路径等。支持 schema v9/v10，v9 通过适配器转换。资源文件从 EPUB 中按需提取（字体 + CSS 背景图）。

---

### 1.10 ShelfOrganizationRepository.kt

**类/接口/object：**
- `data class ShelfOrganizationSnapshot(groups, groupCounts, tags, tagCounts, tagRefs)` — 书架组织快照
- `@Singleton class ShelfOrganizationRepository(dao)` — 书架组织仓库

**public 方法摘要：**
- `snapshot: Flow<ShelfOrganizationSnapshot>` — 观察书架组织全貌
- `saveGroup/createOrGetGroup/createOrGetGroupPath/deleteGroup/setGroupParent/reorderGroups` — 分组管理
- `moveBooksToGroup/setBookGroup` — 书籍分组操作
- `saveTag/createOrGetTag/addTagToBooks/removeTagFromBooks/deleteTag/deleteTags` — 标签管理
- `setTagsGroup/reorderTags/mergeTags` — 标签分组/排序/合并

**功能描述：** 书架分组与标签的统一管理。分组支持多级路径，标签支持分组与颜色。提供组合快照流供 UI 消费。

---

### 1.11 IllustrationRepository.kt

**类/接口/object：**
- `@Singleton class IllustrationRepository(context, dao)` — 插图仓库

**public 方法摘要：**
- `observeForBook(bookId): Flow<List<IllustrationEntity>>` — 观察书籍插图
- `get(id): IllustrationEntity?` — 单条查询
- `backfillLegacyFiles(bookId)` — 回填旧版生图文件到插图廊
- `insert(illustration): IllustrationEntity` — 插入插图
- `delete(illustration)` — 删除插图（同时删文件）

**功能描述：** AI 生成插图的管理，支持从旧版文件系统回填元数据。删除时同步删除应用私有目录内的图片文件。

---

### 1.12 NoteExporter.kt

**类/接口/object：**
- `@Singleton class NoteExporter(context)` — 笔记导出器

**public 方法摘要：**
- `buildMarkdown(bookTitle, notes): String` — 生成 Markdown 文本
- `exportToDocuments(bookTitle, notes): String?` — 导出到系统 Documents/墨知 目录
- `buildShareIntent(bookTitle, notes): Intent?` — 生成分享 Intent

**功能描述：** 读书笔记导出为 Markdown 格式。支持写入 Documents 目录（通过 MediaStore）或通过 FileProvider 分享。剧情梗概在前，笔记按章节排序。

---

### 1.13 BookQuoteLocator.kt（object）

**类/接口/object：**
- `data class QuoteLocation(chapterIndex, startCharOffset, endCharOffset)` — 引文位置
- `data class QuoteChapter(chapterIndex, body)` — 定位所需章节
- `object BookQuoteLocator` — 引文定位器（单例对象）

**public 方法摘要：**
- `locateAll(chapters, quote): List<QuoteLocation>` — 全匹配，返回所有命中
- `locateBest(chapters, quote, preferredChapterIndex): QuoteLocation?` — 宽松定位（先全匹配，失败则归一化标点再匹配，取最近章节）
- 常量：`MIN_QUOTE_CHARS = 6`

**功能描述：** 在书中逐字定位一段引文。用于 AI 批注落地校验和聊天页「跳到原文」。支持归一化匹配（忽略空白与常见标点），解决模型复述时标点不一致的问题。

---

### 1.14 AnnotationMedia.kt

**类/接口/object：**
- `data class AnnotationMedia(audioPath, illustrationId)` — 批注媒体数据

**public 方法/函数：**
- `isEmpty: Boolean` — 是否为空
- `encode(): String` — 序列化为 JSON
- `companion decode(raw): AnnotationMedia` — 从 JSON 反序列化

**功能描述：** 批注附带的媒体信息（语音路径、插图 ID）的序列化封装。存储在 annotation 表的 mediaJson 字段。

---

### 1.15 AttachmentStore.kt

**类/接口/object：**
- `data class MessageAttachment(type, path, mime, name)` — 消息附件
- `@Singleton class AttachmentStore(context)` — 消息附件存储

**public 方法摘要：**
- `saveImage(conversationId, uri): MessageAttachment?` — 保存图片附件（压缩到长边 1568px）
- `saveTextFile(conversationId, uri, displayName): MessageAttachment?` — 保存文本文件附件
- `loadImageBase64(attachment): String?` — 加载图片为 Base64
- `loadTextContent(attachment): String?` — 加载文本内容
- `resolve(attachment): File` — 解析为文件
- `deleteFor(conversationId)` — 删除会话全部附件

**功能描述：** 聊天消息附件的落盘管理。图片压缩到长边 ≤1568px JPEG q85 以控制 token。DB 只存相对路径，删会话时清理目录。

---

### 1.16 LegacyLocatorConverter.kt（object）

**类/接口/object：**
- `data class LegacyLocator(href, progression)` — 旧版定位器
- `object LegacyLocatorConverter` — 旧版定位器转换器

**public 方法摘要：**
- `resolveChapterIndex(locatorHref, readingOrderHrefs, fallbackIndex): Int` — 解析章节索引
- `parse(locatorJson): LegacyLocator?` — 解析 JSON 定位器
- `progressionToCharOffset(progression, charCount): Int` — 进度百分比转字符偏移

**功能描述：** 将 Readium 时代的 locator JSON 转换为新的 (chapterIndex, charOffset) 坐标。假设均匀字符密度，用于旧书签迁移。

---

### 1.17 EpubResourcePath.kt（object）

**类/接口/object：**
- `object EpubResourcePath` — EPUB 资源路径工具

**public 方法摘要：**
- `normalize(href, baseHref): String?` — 规范化资源路径（解析相对路径、URL 解码、防路径穿越）
- `matchKnown(href, knownHrefs): String?` — 在已知资源列表中匹配
- `packageAliases(href, packageDocumentPath): List<String>` — 生成包内路径别名（绝对 + 相对）

**功能描述：** EPUB 资源路径的规范化与匹配工具。处理相对路径、URL 解码、`..` 穿越防护，以及包内路径的多别名匹配。

---

### 1.18 EpubLayoutModels.kt

**类/接口/object：**
- `data class EpubLayoutPackage(schemaVersion, packageDocumentPath, resources, spine, fontFaces, stylesheets, chapters, diagnostics, ...)` — EPUB 布局包
- `data class EpubLayoutResource(id, href, archivePath, mediaType, properties, kind, sizeBytes, sha256)` — 资源条目
- `enum class EpubLayoutResourceKind { DOCUMENT, STYLESHEET, IMAGE, SVG, FONT, NAVIGATION, OTHER }` — 资源类型
- `data class EpubLayoutSpineItem(index, idref, href, linear, properties)` — spine 条目
- `data class EpubStylesheetText(href, css)` — 样式表文本
- `data class EpubFontFace(family, resourceHref, weight, italic)` — 字体声明
- `data class EpubBoxShadow(offsetXEm, offsetYEm, blurRadiusEm, spreadRadiusEm, colorArgb, inset)` — 阴影
- `data class EpubLayoutChapterRef(chapterIndex, href, textLength, fileName)` — 章节引用
- `@Deprecated data class EpubLayoutChapter(...)` — v9 兼容章节布局模型
- `data class EpubLayoutBlock(orderIndex, kind, textStart, textEnd, element, ancestors, style, spans, ...)` — 块级布局
- `enum class EpubLayoutBlockKind { PARAGRAPH, HEADING, QUOTE, LIST_ITEM, CONTAINER, IMAGE, SEPARATOR }` — 块类型
- `data class EpubLayoutSpan(textStart, textEnd, elements, style, linkHref, rubyText)` — 行内 span
- `data class EpubElementRef(tag, id, classes, inlineStyle)` — 元素引用
- `data class EpubComputedStyle(...)` — 计算样式（字体/颜色/边距/边框/阴影等 50+ 字段）
- 多个样式相关枚举：`EpubBackgroundSizeMode`, `EpubTextAlign`, `EpubVerticalAlign`, `EpubFloat`, `EpubLayoutMode`
- `data class EpubLayoutDiagnostic(severity, code, message, href)` — 诊断信息
- `data class EpubLayoutChapterInput(chapterIndex, href, document, dom)` — 章节输入
- `data class EpubResolvedFontFace(family, filePath, weight, italic)` — 已解析字体
- `data class EpubLayoutChapterBundle(document, resourcePaths, fontPaths, fontFaces, dom, stylesheets)` — 章节布局包

**功能描述：** EPUB 布局的全套数据模型。从 DOM 结构、块级/行内布局、计算样式到资源、字体、样式表，定义了阅读器渲染所需的全部结构化数据。schema 版本当前为 v10。

---

## 二、core/speech/ — 语音 / TTS

### 2.1 SystemTtsSpeaker.kt

**类/接口/object：**
- `data class SystemTtsEngineInfo(packageName, label)` — 系统 TTS 引擎信息
- `@Singleton class SystemTtsSpeaker(context)` — 系统 TTS 门面

**public 方法摘要：**
- `engines(): List<SystemTtsEngineInfo>` — 枚举已安装 TTS 引擎
- `speak(text, settings): Boolean` — 朗读单段文本（按引擎输入上限分段 QUEUE_ADD）
- `speakBatch(utterances, settings, onUtteranceStart): Boolean` — 批量朗读（整批 QUEUE_ADD，每句开播时回调）
- `stop()` — 停止朗读
- `release()` — 释放引擎实例
- `isSpeaking: StateFlow<Boolean>` — 朗读状态流

**功能描述：** 系统 TTS（android.speech.tts.TextToSpeech）的封装门面。支持指定第三方引擎（如 Multi TTS）、语言/语速/音调/音量补偿。实例按引擎包名缓存，长文自动按引擎输入上限分段。批量模式支持句级进度回调。

---

### 2.2 TtsSettingsStore.kt

**类/接口/object：**
- `enum class TtsEngineMode { SYSTEM, AI }` — TTS 引擎模式
- `enum class TtsSynthesisGranularity { SENTENCE, PARAGRAPH, CHAPTER }` — 合成粒度
- `enum class TtsApiProvider { MINIMAX_CN, MINIMAX_INTL, OPENAI_COMPAT, GMI_CLOUD }` — 独立 TTS 服务商
- `data class TtsSettings(engineMode, systemEnginePackage, systemLanguageTag, systemRate, systemPitch, aiVoiceId, aiSpeed, aiVolume, aiPitch, aiProvider, aiBaseUrl, aiGroupId, aiModel, allowAudioMixing, trimSilence, synthesisGranularity, maxSynthesisChars, synthesisConcurrency, retryCount, prefetchCount, systemVolumeCompensation, audiobookEnginePolicy)` — TTS 完整配置
- `@Singleton class TtsSettingsStore(dataStore)` — TTS 设置存储

**public 顶层函数：**
- `TtsApiProvider.defaultBaseUrl(): String` — 默认 Base URL
- `TtsApiProvider.defaultModel(): String` — 默认模型名

**public 方法摘要：**
- `settings: Flow<TtsSettings>` — 观察设置
- `current(): TtsSettings` — 当前设置
- `update(transform)` — 更新设置

**功能描述：** 语音朗读的全部配置存储，包括系统 TTS 和 AI TTS 两套参数。支持独立 TTS API（MiniMax/OpenAI 兼容/GMI 云），以及合成粒度、并发、预取、重试等高级参数。

---

### 2.3 TtsVoiceRepository.kt

**类/接口/object：**
- `@Singleton class TtsVoiceRepository(dao)` — TTS 音色仓库

**public 方法摘要：**
- `voices: Flow<List<TtsVoiceEntity>>` — 观察音色列表
- `getVoices(): List<TtsVoiceEntity>` — 获取音色（支持 JS 模块 hook 注入）
- `save(voice): Long` — 保存音色
- `delete(voice)` — 删除音色
- `importMiniMaxPresets()` — 导入 MiniMax 预设音色

**功能描述：** AI TTS 音色的本地管理。支持通过 `tts.voices` hook 从 JS 模块动态注入音色列表。内置 MiniMax 预设音色导入。

---

### 2.4 SentenceSegmenter.kt（object）

**类/接口/object：**
- `data class SentenceSpan(start, end)` — 句子区间（UTF-16 字符坐标）
- `object SentenceSegmenter` — 句子切分器

**public 方法摘要：**
- `segment(body, maxChars): List<SentenceSpan>` — 按句切分（终止标点断句，超长句在次级停顿折分）
- `segmentParagraphs(body, maxChars): List<SentenceSpan>` — 按段落粒度切分（整段优先，超长退回句边界）
- `segmentChapter(body, maxChars): List<SentenceSpan>` — 按章节粒度切分（多段合并直到上限）
- `indexAt(spans, offset): Int` — 查找偏移所在句子的索引
- `speakableText(body, start, end): String` — 提取送进 TTS 的文本（替换内联图占位符为空格）
- 常量：`DEFAULT_MAX_CHARS = 96`

**功能描述：** 听书句子切分核心算法。按行切段，段内按终止标点（。！？等）断句并将收尾引号归前句。超长句在逗号/顿号/冒号/空格等次级停顿处折分，实在没有停顿则硬切。支持 `listen.sentence` JS hook 覆盖。

---

### 2.5 SleepTimerPlanner.kt（object）

**类/接口/object：**
- `sealed interface SleepTimerPlan` — 定时停止计划
  - `data class Minutes(minutes)` — 定时 N 分钟
  - `data class Chapters(chapters)` — 定时 N 章
  - `object EndOfChapter` — 本章结束停止
- `data class SleepTimerState(plan, remainingMillis, remainingChapters, running)` — 定时器状态
- `object SleepTimerPlanner` — 定时器规划器

**public 方法摘要：**
- `start(plan): SleepTimerState` — 启动计时
- `tick(state, elapsedMillis, playing): SleepTimerState` — 时间推进
- `onChapterCompleted(state): SleepTimerState` — 章节完成推进
- `isExpired(state): Boolean` — 是否已到期
- `label(state): String` — 显示文本

**功能描述：** 听书睡眠定时的纯函数状态机。支持三种模式：定时分钟、定章节数、本章结束。与播放状态解耦，易于测试。

---

### 2.6 SpeechCacheStore.kt

**类/接口/object：**
- `data class SpeechCacheStats(fileCount, totalBytes, budgetBytes, autoSyncOnWifi, lastSyncAt)` — 缓存统计
- `data class SpeechCacheBookStats(bookId, fileCount, totalBytes)` — 单书缓存统计
- `@Singleton class SpeechCacheStore(context, dataStore)` — 语音缓存存储

**public 方法摘要：**
- `directory(): File` / `directoryFor(bookId): File` — 缓存目录
- `settings: Flow<SpeechCacheStats>` — 观察设置
- `stats(): SpeechCacheStats` — 统计信息
- `budgetBytes(): Long` / `setBudgetBytes(value)` — 容量预算管理
- `setAutoSyncOnWifi(enabled)` / `markSynced(now)` — 自动同步设置
- `clear()` / `clearBook(bookId): Long` — 清空缓存
- `statsByBook(): List<SpeechCacheBookStats>` — 按书统计
- `audioFiles(): List<File>` — 列出全部音频文件
- `migrateLegacyCache()` — 迁移旧版 cacheDir 缓存
- `enforceBudget(): Long` — 执行预算淘汰（LRU，按最久未用删起）

**功能描述：** AI 合成语音的本地缓存管理。存储在 filesDir（避免系统清空 cacheDir 导致重新付费合成）。支持全局容量预算（默认 300MB），按 LRU 淘汰。支持 WebDAV 自动同步开关。

---

### 2.7 SpeechCacheSync.kt

**类/接口/object：**
- `data class SpeechCacheSyncResult(uploaded, downloaded, skipped)` — 同步结果
- `@Singleton class SpeechCacheSync(cache, webDav, backupSettings)` — 语音缓存同步

**public 方法摘要：**
- `credentialsOrNull(): WebDavCredentials?` — 获取同步凭据
- `sync(): SpeechCacheSyncResult` — 执行双向同步

**功能描述：** 语音缓存的 WebDAV 双向同步。文件名为内容哈希（模型+音色+参数+文本），因此「同名即同内容」，两端补齐缺的文件即可，无冲突。换设备/重装后同一段文字不必再花钱合成。受本地预算约束。

---

### 2.8 SpeechCacheSyncWorker.kt

**类/接口/object：**
- `interface SpeechCacheSyncEntryPoint` — Hilt EntryPoint
- `class SpeechCacheSyncWorker(appContext, parameters) : CoroutineWorker` — 同步 Worker

**public 方法/伴生对象：**
- `schedule(context)` — 调度 12 小时周期任务（仅未计费 Wi-Fi）
- `cancel(context)` — 取消任务

**功能描述：** 语音缓存的 WorkManager 自动同步。只在不计费网络（Wi-Fi）下运行，每 12 小时一次。指数退避重试。

---

## 三、core/datastore/ — 设置存储

### 3.1 ReaderSettingsRepository.kt

**类/接口/object：**
- `enum class ReaderTheme { SYSTEM, LIGHT, DARK, PAPER, EYE_CARE, AMOLED, MIST }` — 阅读主题
- `enum class PageMode { PAGINATED, SCROLL }` — 翻页模式
- `enum class PageTurnAnimation { SIMULATION, COVER, SLIDE, NONE }` — 翻页动画
- `enum class ReaderFont { SYSTEM, SERIF, SANS_SERIF, MONOSPACE, CUSTOM }` — 字体
- `enum class PublisherStyleMode { RESPECT, SMART, TAKE_OVER }` — 出版商样式处理模式
- `enum class ShelfLayout { GRID, LIST }` — 书架布局
- `const val FOLLOW_SYSTEM_BRIGHTNESS = -1f` — 跟随系统亮度哨兵值
- `data class ReaderSettings(...)` — 完整阅读设置（60+ 字段）
- `@Singleton class ReaderSettingsRepository(dataStore)` — 阅读设置仓库

**public 方法摘要（分类）：**
- **外观主题**：`setTheme/setDayNightThemeAuto/setBookThemeEnabled/setBookTheme/selectBookCustomTheme/saveCustomTheme/saveBookCustomTheme/deleteCustomTheme/selectCustomTheme`
- **字体排版**：`setFontScale/setFont/addCustomFont/selectCustomFont/renameCustomFont/removeCustomFont/setCustomFont/setFontWeight/setLineHeight/setPublisherStyleMode/setPageMargin/setPageMarginLeft/Right/Top/Bottom/setHeaderMarginTop/setFooterMarginBottom/setLetterSpacingEm/setParagraphSpacingEm/setFirstLineIndentEm/setTitleScale/setTitleTopSpacing/setTitleBottomSpacing/setTextJustification`
- **界面元素**：`setShowHeader/setShowFooter/setPageMode/setPageTurnAnimation/setShelfLayout/setKeepScreenOn/setImmersiveReading/setVolumeKeysPageTurn/setScreenBrightness`
- **背景图片**：`setBackgroundImagePath/addReaderImage/selectBackgroundImage/renameReaderImage/removeReaderImage/setBackgroundImageOpacity`
- **语法高亮**：`setSyntaxHighlightEnabled/saveSyntaxHighlightRule/deleteSyntaxHighlightRule`
- **文本替换**：`saveTextReplacementRule/deleteTextReplacementRule`
- **伴读设置**：`setActivePersonaId/setSuggestionRepliesEnabled/setCompanionSpoilerProtectionEnabled/setCompanionLongTermMemory/setCompanionCrossBookMemory/setCompanionCrossBookChatSearch/setShowAiAnnotations/setLastAnnotationInk/setCompanionMultiBubbleEnabled/setCompanionVoiceReplies/setCompanionImageReplies/setCompanionProactiveAnnotations/setCompanionProactiveAnnotationVoice/setCompanionProactiveAnnotationImage`
- **主题/外观**：`setThemeMode/setAccentPreset/setCustomAccent`
- **流**：`settings: Flow<ReaderSettings>`, `cachedSettings: StateFlow<ReaderSettings>`, `appearance: Flow<AppearanceSettings>`, `activePersonaId: Flow<Long?>`, `companionMemorySettings: Flow<CompanionMemorySettings>`, `companionAutonomySettings: Flow<CompanionAutonomySettings>` 等

**功能描述：** 阅读与伴读相关全部设置的统一入口。基于 DataStore Preferences，提供 50+ 个设置项的读写。支持日夜双槽主题、逐书主题、自定义主题、字体库、图片库、语法高亮、文本替换规则等高级功能。含进程级热缓存避免首帧跳变。

---

### 3.2 BookReaderTheme.kt

**类/接口/object：**
- `data class BookReaderTheme(enabled, dayTheme, dayCustomThemeId, nightTheme, nightCustomThemeId)` — 逐书主题
- `object BookReaderThemeCodec` — 序列化编解码器
- 顶层扩展函数：`ReaderSettings.withBookThemeSelection(bookId)`, `ReaderSettings.resolveForBook(bookId, slot)`

**功能描述：** 逐书主题配置的数据模型与编解码。每本书可独立启用日/夜主题，支持内置主题和自定义主题。提供解析函数将全局设置与本书主题合并。

---

### 3.3 CustomReaderTheme.kt

**类/接口/object：**
- `data class CustomReaderTheme(id, name, backgroundArgb, textArgb, accentArgb, isDark, font, customFontId, customFontPath, customFontName, fontScale, fontWeight, lineHeight, pageMargins, ...)` — 自定义主题（40+ 字段）
- `object CustomReaderThemeCodec` — 编解码器

**功能描述：** 用户自定义阅读主题的数据模型。除配色外同时保存字体、字号、排版、背景等完整阅读体验，便于在日/夜间方案间一键切换。逐项解码避免单个损坏主题导致整表丢失。

---

### 3.4 ReaderThemeSlots.kt

**类/接口/object：**
- `enum class ReaderThemeSlot { DAY, NIGHT }` — 主题槽位
- 顶层扩展函数：`ReaderSettings.activeThemeSlot(dark)`, `themeFor(slot)`, `customThemeIdFor(slot)`, `customThemeFor(slot)`, `backgroundImageIdFor(slot)`, `backgroundImagePathFor(slot)`, `backgroundOpacityFor(slot)`, `resolveThemeSlot(slot)`

**功能描述：** 阅读纸色的日/夜双槽机制。日夜自动切换时只换外观（纸色、正文色、强调色、背景图），字号行距边距等排版两边共用。提供一组扩展函数简化槽位访问。

---

### 3.5 ReaderTextReplacementRule.kt

**类/接口/object：**
- `data class ReaderTextReplacementRule(id, name, pattern, replacement, enabled, ignoreCase, forListenOnly)` — 文本替换规则
- `object ReaderTextReplacementRuleCodec` — 编解码器
- `fun ReaderTextReplacementRule.compileRegex(): Regex` — 编译正则
- `fun ReaderTextReplacementRule.validationError(): String?` — 校验规则
- `data class ListenTextSlice(startCharOffset, endCharOffset, text)` — 听书文本切片
- `fun purifyForListening(body, startCharOffset, endCharOffset, rules): ListenTextSlice` — 听书专用文本净化
- `fun audiobookRevision(body, rules): Int` — 有声书剧本版本指纹

**功能描述：** 用户自定义正文清洗/替换规则。支持仅用于听书的规则（不改变原文坐标，只影响 TTS 输入）。含正则编译和校验。有声书剧本版本指纹用于判断规则变化是否需要重新生成剧本。

---

### 3.6 ReaderFontLibrary.kt

**类/接口/object：**
- `data class ReaderFontAsset(id, displayName, filePath, originalFileName, importedAt)` — 字体资产
- `object ReaderFontLibraryCodec` — 编解码器（含旧版单字体兼容）

**功能描述：** 已导入字体库的数据模型与序列化。支持从旧版单字体配置无损迁移到字体库，稳定 ID 避免重复项。

---

### 3.7 ReaderImageLibrary.kt

**类/接口/object：**
- `data class ReaderImageAsset(id, displayName, filePath, originalFileName, width, height, importedAt)` — 图片资产
- `object ReaderImageLibraryCodec` — 编解码器（含旧版单背景兼容）

**功能描述：** 阅读背景图片库的数据模型与序列化。图片可被多本书和阅读背景复用，书籍生命周期不得删除它。

---

### 3.8 ReaderSyntaxHighlight.kt

**类/接口/object：**
- `enum class ReaderSyntaxMatchMode { DELIMITED, REGEX }` — 匹配模式
- `enum class ReaderSyntaxFont { INHERIT, SYSTEM, SERIF, SANS_SERIF, MONOSPACE, CUSTOM }` — 字体选项
- `data class ReaderSyntaxRule(id, name, startDelimiter, endDelimiter, colorArgb, includeDelimiters, underline, enabled, matchMode, pattern, ignoreCase, backgroundArgb, font, fontAssetId, bold, italic, strikethrough)` — 语法规则
- `data class ReaderSyntaxStyleSpan(start, endExclusive, colorArgb, backgroundArgb, underline, font, fontAssetId, bold, italic, strikethrough, ruleId)` — 样式 span
- `object ReaderSyntaxHighlighter` — 语法高亮引擎
- `object ReaderSyntaxRuleCodec` — 编解码器

**public 方法摘要：**
- `ReaderSyntaxHighlighter.spans(text, rules): List<ReaderSyntaxStyleSpan>` — 计算样式 span
- 常量：`DEFAULT_RULES`（人物对白、直角引号、书名与作品）

**功能描述：** 成对符号包裹内容的阅读美化（如对话引号着色）。支持分隔符模式和正则模式，可配置颜色、背景、字体、加粗、斜体、下划线、删除线等样式。列表靠前的规则优先。

---

### 3.9 BookEmbeddingSettingsStore.kt

**类/接口/object：**
- `@Singleton class BookEmbeddingSettingsStore(dataStore)` — 书籍嵌入设置存储

**public 方法摘要：**
- `enabledBookIds: Flow<Set<Long>>` — 观察已启用向量索引的书籍
- `isEnabled(bookId): Boolean` — 查询单本是否启用
- `setEnabled(bookId, enabled)` — 设置启用状态

**功能描述：** 用户明确选择建立 AI 向量索引的书籍。未选择的书只使用本地关键词（BM25）检索，不消耗 embedding API 调用。

---

### 3.10 CompanionMemorySettings.kt

**类/接口/object：**
- `data class CompanionMemorySettings(longTermEnabled, crossBookEnabled, crossBookChatSearchEnabled)` — 伴读记忆设置

**功能描述：** 伴读记忆的范围开关。长期记忆默认开，跨书能力默认关。关闭 ≠ 删除，既有记忆保留只是不参与检索。

---

### 3.11 CompanionAutonomySettings.kt

**类/接口/object：**
- `data class CompanionAutonomySettings(voiceRepliesEnabled, imageRepliesEnabled, proactiveAnnotationsEnabled, proactiveAnnotationVoiceEnabled, proactiveAnnotationImageEnabled)` — 伴读自主调用设置

**属性：**
- `annotationVoiceActive: Boolean` — 段评语音是否实际生效
- `annotationImageActive: Boolean` — 段评图片是否实际生效
- `anyEnabled: Boolean` — 是否有任何一项主动调用开启

**功能描述：** AI agent 主动发起付费调用的总闸。凡是 agent 自己决定发起的付费调用（自主语音、自主生图、随读段评）都能单独关掉，且默认保守关闭。关闭语义是「彻底不给能力」而非「拦住」。

---

### 3.12 GlobalPromptPresetStore.kt

**类/接口/object：**
- `enum class GlobalPromptInjectionPosition { BEFORE_SYSTEM, AFTER_SYSTEM, BEFORE_LAST_USER, AFTER_LAST_USER }` — 注入位置
- `data class GlobalPromptPreset(id, name, prompt, enabled, position, builtIn)` — 全局提示词预设
- `@Singleton class GlobalPromptPresetStore(dataStore)` — 预设存储

**public 方法摘要：**
- `presets: Flow<List<GlobalPromptPreset>>` — 观察预设列表
- `current(): List<GlobalPromptPreset>` — 当前预设
- `upsert(preset)` — 新增/更新
- `setEnabled(id, enabled)` — 开关
- `delete(id)` — 删除

**功能描述：** 全局提示词预设管理（类似 SillyTavern Prompt Manager）。支持四个注入位置：system 前后、最后一条 user 前后。内置三条默认预设：自然表达、沉浸式角色扮演、简洁回答。

---

### 3.13 ProactiveAnnotationQuota.kt

**类/接口/object：**
- `data class ProactiveAnnotationQuotaState(epochDay, attemptedChapters, annotationCount, voiceCount, imageCount)` — 配额状态
- `data class ProactiveAnnotationAllowance(accepted, maxAnnotations, maxVoice, maxImages)` — 配额许可
- `@Singleton class ProactiveAnnotationQuota(dataStore)` — 随读段评配额

**public 方法摘要：**
- `reserve(bookId, chapterIndex, requestVoice, requestImages, today): ProactiveAnnotationAllowance` — 预扣配额
- `recordCreated(annotations, voices, images, today)` — 记录实际产出
- `snapshot(today): ProactiveAnnotationQuotaState` — 快照

**功能描述：** 随读段评（AI 主动批注）的日配额管理。每日上限：10 条批注、3 条语音、3 张图片，且每章只尝试一次。防止 AI 自主调用过度消耗 API 额度。

---

### 3.14 UserMaskStore.kt

**类/接口/object：**
- `data class UserMask(id, name, description)` — 用户面具
- `data class UserMaskSettings(enabled, activeMaskId, masks)` — 面具设置
- `@Singleton class UserMaskStore(dataStore)` — 用户面具存储

**public 方法摘要：**
- `settings: Flow<UserMaskSettings>` — 观察设置
- `activeMask(): UserMask?` — 当前激活面具
- `setEnabled(enabled)` — 开关
- `select(id)` — 选择
- `save(mask): Long` — 保存
- `delete(id)` — 删除

**功能描述：** 用户侧身份面具（类似 SillyTavern user persona）。描述「我是谁」，不替代 AI 角色卡。记忆固化据此区分本人偏好与面具内经历。

---

### 3.15 ReaderFontImporter.kt

**类/接口/object：**
- `data class PendingReaderFont(cachePath, originalFileName, detectedName, extension)` — 待导入字体
- `@Singleton class ReaderFontImporter(context, settingsRepository)` — 字体导入器
- `internal object SfntFontNameReader` — OpenType/TrueType name 表读取器

**public 方法摘要：**
- `supports(uri): Boolean` — 判断是否支持
- `prepare(uri): PendingReaderFont` — 准备导入（复制到缓存 + 可用性校验 + name 表识别）
- `confirm(pending, customName): ReaderFontAsset` — 确认导入
- `rename(fontId, displayName)` — 重命名
- `delete(font)` — 删除
- `discard(pending)` — 丢弃待导入

**功能描述：** 阅读自定义字体的导入流程。统一承接阅读页选择器与系统「其他应用打开」。支持 TTF/OTF/TTC 格式，64MB 上限。自动从字体 name 表识别显示名（优先完整名称，回退家族名）。

---

### 3.16 ReaderImageImporter.kt

**类/接口/object：**
- `data class PendingReaderImage(cachePath, originalFileName, width, height, extension)` — 待导入图片
- `@Singleton class ReaderImageImporter(context, settingsRepository)` — 图片导入器

**public 方法摘要：**
- `supports(uri): Boolean` — 判断是否支持
- `prepare(uri): PendingReaderImage` — 准备导入
- `confirm(pending, displayName, selectAsBackground): ReaderImageAsset` — 确认导入
- `rename(imageId, displayName)` — 重命名
- `delete(image)` — 删除
- `discard(pending)` — 丢弃

**功能描述：** 阅读背景图片的导入流程。图片存入应用私有目录的图片库，可被多本书和阅读背景复用。

---

## 四、core/database/ — 数据库（Room）

### 4.1 MoReadDatabase.kt

**类/接口/object：**
- `@Database abstract class MoReadDatabase : RoomDatabase` — 主数据库

**DAO 访问方法：**
- `abstract fun bookDao(): BookDao`
- `abstract fun aiProviderDao(): AiProviderDao`
- `abstract fun chatDao(): ChatDao`
- `abstract fun personaDao(): PersonaDao`
- `abstract fun annotationDao(): AnnotationDao`
- `abstract fun noteDao(): NoteDao`
- `abstract fun illustrationDao(): IllustrationDao`
- `abstract fun shelfOrganizationDao(): ShelfOrganizationDao`
- `abstract fun ttsVoiceDao(): TtsVoiceDao`
- `abstract fun audiobookDao(): AudiobookDao`

**实体列表（22 个表）：**
- 书籍相关：`BookEntity`, `ChapterEntity`, `BookTocEntryEntity`, `BookmarkEntity`, `ReadingDailyEntity`
- AI 相关：`AiProviderEntity`, `AiModelEntity`, `ModelAssignmentEntity`
- 聊天相关：`ConversationEntity`, `MessageEntity`
- 伴读相关：`PersonaEntity`
- 批注/笔记/插图：`AnnotationEntity`, `AnnotationReplyEntity`, `AiCreationEntity`, `AiCreationVersionEntity`, `NoteEntity`, `IllustrationEntity`
- 书架组织：`ShelfGroupEntity`, `BookTagEntity`, `BookTagRefEntity`
- TTS/有声书：`TtsVoiceEntity`, `AudiobookRoleEntity`, `AudiobookSegmentEntity`, `AudiobookChapterEntity`

**功能描述：** 应用的主 Room 数据库，版本号 22，含 22 个实体表。覆盖书籍、章节、目录、书签、阅读统计、AI 提供商/模型、对话/消息、角色、批注、笔记、插图、书架分组/标签、TTS 音色、有声书角色/分段/章节等全部持久化数据。

---

### 4.2 entity/LibraryEntities.kt（核心实体）

**类/接口/object：**
- `enum class BookSourceType { TXT, EPUB }` — 书籍来源类型
- `enum class AiProviderType { CHAT, EMBEDDING, TTS, IMAGE }` — AI 提供商能力类型
- `enum class AiProviderAdapter { CUSTOM, OPENROUTER, OPENAI, ANTHROPIC, GEMINI, DEEPSEEK, MINIMAX }` — 提供商适配器
- `enum class AiModelType { CHAT, EMBEDDING, TTS, IMAGE }` — 模型能力类型
- `enum class ModelRole { CHAT, CHEAP, SUGGESTION, EMBEDDING, TTS, IMAGE }` — 模型角色分配
- `@Entity data class BookEntity(id, title, author, coverPath, epubPath, sourceType, importedAt, totalChapters, lastReadLocator, lastReadChapterIndex, lastReadCharOffset, maxReachedChapterIndex, maxReachedCharOffset, lastReadAt, textVersion, tags, metadataEdited, manualReadState, pinnedAt, groupId)` — 书籍
- `enum class BookReadState { UNREAD, READING, FINISHED, SHELVED }` — 阅读状态
- `fun BookEntity.readState(): BookReadState` — 计算阅读状态（手动优先，否则按进度推导）
- `@Entity data class ChapterEntity(id, bookId, chapterIndex, title, href, charCount, textByteOffset, textByteLength)` — 章节
- `@Entity data class BookTocEntryEntity(id, bookId, orderIndex, title, href, depth, parentOrderIndex, chapterIndex, hasChildren)` — 目录条目
- `@Entity data class BookmarkEntity(id, bookId, locatorJson, chapterIndex, charOffset, excerpt, label, createdAt)` — 书签
- `@Entity data class ReadingDailyEntity(bookId, epochDay, durationMs, lastReadAt)` — 每日阅读统计
- `@Entity data class AiProviderEntity(id, name, baseUrl, apiKeyAlias, type, extraJson, apiFormat, adapter, createdAt)` — AI 提供商
- `@Entity data class AiModelEntity(id, providerId, modelName, type, chatApiFormat, endpointPath, extraJson, createdAt)` — AI 模型
- `@Entity data class ConversationEntity(id, bookId, personaId, title, type, parentConversationId, branchedFromMessageId, memoryConsolidatedThroughMessageId, rollingSummary, summarizedThroughMessageId, createdAt, updatedAt)` — 会话
- `@Entity data class MessageEntity(id, conversationId, role, content, toolCallsJson, toolCallId, tokenUsage, createdAt, editedAt, attachmentsJson, reasoningContent, maskId, sourceScopeChapterIndex, sourceScopeCharOffset)` — 消息
- `@Entity data class ModelAssignmentEntity(role, modelId)` — 模型角色分配

**功能描述：** 定义了书籍库、AI 提供商/模型、对话/消息等核心实体。书籍实体含丰富的阅读进度字段（含防剧透高水位 maxReached*）。消息实体含思维链、附件、用户面具、检索范围边界等伴读功能字段。

---

### 4.3 dao/BookDao.kt

**类/接口/object：**
- `@Dao interface BookDao` — 书籍 DAO

**主要查询/操作（按类别）：**
- **观察流**：`observeBooks`, `observeBook`, `observeChapters`, `observeTocEntries`, `observeBookmarks`, `observeReadingDays`, `observeAllReadingDays`
- **书籍 CRUD**：`getBooks`, `getBook`, `insertBook`, `updateBook`, `deleteBook`, `updateBookMetadata`, `updateReadState`, `updatePinnedAt`, `replaceBookCover`
- **封面/目录**：`getBooksMissingCovers`, `getBooksMissingToc`, `getBooksWithReExtractableCovers`, `clearCoverPaths`, `updateBookCover`, `deleteTocEntriesForBook`, `insertTocEntries`
- **阅读进度**：`updateProgress`, `updateReadPosition`, `resetReadingHighWater`, `saveProgress`
- **章节/正文**：`insertChapters`, `deleteChaptersForBook`, `getChapters`, `getChapter`, `getTotalCharacterCount`, `getCharacterCountBefore`, `updateChapterTextRange`, `updateTextVersion`, `getBooksBelowTextVersion`, `getChapterTitle`
- **书签**：`insertBookmark`, `getBookmarks`, `deleteBookmark`, `updateBookmarkPosition`
- **阅读统计**：`insertReadingDay`, `addReadingDuration`, `getReadingDays`
- **标签**：`getTagNames`

**功能描述：** 书籍相关的全部数据库操作接口。提供 Flow 观察和一次性读取两种访问方式。支持事务级更新，含正文文本版本控制、防剧透高水位、阅读时长跨天分段等高级逻辑。

---

### 4.4 其他 DAO（概览）

| DAO 文件 | 实体 | 主要职责 |
|----------|------|----------|
| `dao/AnnotationDao.kt` | `AnnotationEntity`, `AnnotationReplyEntity` | 批注与讨论串回复 CRUD、计数、按章/按范围查询 |
| `dao/NoteDao.kt` | `NoteEntity` | 笔记 CRUD、按书查询、最新按类型查找 |
| `dao/AudiobookDao.kt` | `AudiobookRoleEntity`, `AudiobookSegmentEntity`, `AudiobookChapterEntity` | 有声书角色、分段、章节的 CRUD 与状态流转 |
| `dao/IllustrationDao.kt` | `IllustrationEntity` | 插图 CRUD、按书查询 |
| `dao/ShelfOrganizationDao.kt` | `ShelfGroupEntity`, `BookTagEntity`, `BookTagRefEntity` | 书架分组与标签的 CRUD、排序、移动、合并 |
| `dao/TtsVoiceDao.kt` | `TtsVoiceEntity` | TTS 音色 CRUD、观察列表 |
| `dao/ChatDao.kt` | `ConversationEntity`, `MessageEntity` | 会话与消息 CRUD、记忆固化水位、滚动摘要 |
| `dao/PersonaDao.kt` | `PersonaEntity` | 角色卡 CRUD |
| `dao/AiProviderDao.kt` | `AiProviderEntity`, `AiModelEntity`, `ModelAssignmentEntity` | AI 提供商/模型/角色分配 CRUD |

---

### 4.5 其他数据库文件

| 文件 | 类型 | 功能描述 |
|------|------|----------|
| `DatabaseConverters.kt` | TypeConverter | Room 类型转换器（枚举、集合等） |
| `DatabaseMigrations.kt` | Migration* | 1→22 共 21 个数据库迁移 |
| `PersonaSeeds.kt` | Callback | 数据库首次创建时播种初始角色卡 |
| `ShelfTagBackfill.kt` | 工具 | 标签回填与颜色分配 |
| `entity/ShelfEntities.kt` | Entity | 书架分组、标签、标签引用实体 |
| `entity/CompanionEntities.kt` | Entity | 伴读角色、对话、消息相关实体 |
| `entity/AudiobookEntities.kt` | Entity | 有声书角色、分段、章节实体 |
| `entity/TtsVoiceEntity.kt` | Entity | TTS 音色实体 |
| `entity/PersonaChatAppearance.kt` | Entity | 角色聊天外观实体 |

---

## 五、core/backup/ — 备份与恢复

### 5.1 BackupRepository.kt

**类/接口/object：**
- `data class BackupProgress(phase, completedBytes, totalBytes, percent)` — 备份进度
- `@Singleton class BackupRepository(context, archiveManager, settingsStore, webDavClient)` — 备份仓库

**public 方法摘要：**
- `testConnection()` — 测试 WebDAV 连接
- `listRemote(): List<RemoteBackup>` — 列出远程备份
- `backupToWebDav(mode, onProgress): RemoteBackup` — 备份到 WebDAV（完整/轻量模式）
- `stageRemoteRestore(remoteName, onProgress): BackupManifest` — 从远程下载并准备恢复
- `exportLocal(uri)` — 导出备份到本地 Uri
- `stageLocalRestore(uri): BackupManifest` — 从本地文件准备恢复

**功能描述：** 备份恢复的统一入口。支持 WebDAV 备份（完整模式和轻量模式）、本地文件导入导出。含进度回调、轻量备份自动裁剪（保留最近 7 个）。操作互斥（Mutex）。

---

### 5.2 BackupArchiveManager.kt

**类/接口/object：**
- `enum class BackupMode { LIGHTWEIGHT, FULL }` — 备份模式
- `data class BackupManifest(formatVersion, createdAt, appVersion, databaseVersion, packageName, mode)` — 备份清单
- `@Singleton class BackupArchiveManager(context, database)` — 备份归档管理器
- `object BackupRestoreBootstrap` — 恢复引导器

**public 方法摘要：**
- `create(mode, onProgress): File` — 生成备份 zip
- `stageRestore(input): BackupManifest` — 校验并解压到待恢复目录
- `validate(file): BackupManifest` — 仅校验备份文件
- `BackupRestoreBootstrap.applyPending(context)` — 应用启动时应用已确认的恢复

**功能描述：** 备份包的生成与恢复。Room 数据库 + DataStore 必含；轻量模式只带封面/头像/自定义字体/图片库；完整模式还包含书籍正文、媒体、插图、附件。含 Zip Slip 防护、空间检查、条目限制、大小限制。恢复在应用启动前（Hilt/Room 创建前）完成。

---

### 5.3 WebDavClient.kt

**类/接口/object：**
- `data class RemoteBackup(name, size, modifiedAt)` — 远程备份条目
- `@Singleton class WebDavClient(httpClient)` — WebDAV 客户端
- `class WebDavException(message) : Exception(message)` — WebDAV 异常

**public 方法摘要：**
- `test(credentials)` — 测试连接
- `list(credentials, suffixes): List<RemoteBackup>` — 列目录
- `upload(credentials, file, remoteName, onProgress)` — 上传文件
- `download(credentials, remoteName, output, onProgress)` — 下载文件
- `delete(credentials, remoteName)` — 删除文件

**功能描述：** 基于 OkHttp 的 WebDAV 子集实现（PROPFIND/MKCOL/PUT/GET/DELETE）。沿用 Legado 方案。传输专用 OkHttpClient（放宽超时、绕过 API 诊断日志）。支持 Basic 认证、进度回调。强制 HTTPS。

---

### 5.4 BackupSettingsStore.kt

**类/接口/object：**
- `data class BackupSettings(webDavUrl, username, remoteDirectory, autoBackup, lastBackupAt)` — 备份设置
- `data class WebDavCredentials(baseUrl, username, password, remoteDirectory)` — WebDAV 凭据
- `@Singleton class BackupSettingsStore(dataStore, apiKeyStore)` — 备份设置存储

**public 方法摘要：**
- `settings: Flow<BackupSettings>` — 观察设置
- `current(): BackupSettings` — 当前设置
- `save(settings, password)` — 保存设置（密码存加密存储）
- `hasPassword(): Boolean` / `clearPassword()` — 密码管理
- `credentials(): WebDavCredentials` — 获取完整凭据
- `setAutoBackup(enabled)` / `markBackup(now)` — 自动备份与标记

**功能描述：** WebDAV 备份设置的存储。密码存入 EncryptedSharedPreferences（ApiKeyStore），不存 DataStore。含旧版 Google Drive 字段的清理兼容。

---

### 5.5 WebDavBackupWorker.kt

**类/接口/object：**
- `class WebDavBackupWorker(appContext, parameters) : CoroutineWorker` — 自动备份 Worker

**功能描述：** WebDAV 自动备份的 WorkManager 任务。定期自动备份（默认轻量模式），失败指数退避重试。

---

## 六、core/importer/ — 书籍导入

### 6.1 BookImportGateway.kt（接口）

**类/接口/object：**
- `sealed interface PreparedImport`
  - `data class PreviewReady(sessionId)` — 预览就绪（TXT 分章预览）
  - `data class BookImported(bookId)` — 已直接入库
- `interface BookImportGateway` — 书籍导入网关

**public 方法摘要：**
- `prepare(uri): PreparedImport` — 单本导入（TXT 停在预览，EPUB 直接入库）
- `importDirectly(uri): Long` — 批量导入单本入口（不经预览直接入库）
- `backfillMissingCovers()` — 回填缺失封面
- `backfillMissingEpubToc()` — 回填缺失的 EPUB 目录

**功能描述：** 书籍导入的抽象网关接口。TXT 走分章预览流程，EPUB 直接入库。批量导入走 importDirectly 路径。

---

### 6.2 FolderScanner.kt

**类/接口/object：**
- `data class ScannedBookFile(uri, name, sizeBytes, relativeDirectory)` — 扫描到的候选书
- `@Singleton class FolderScanner(context)` — 文件夹扫描器

**public 方法摘要：**
- `scan(treeUri): List<ScannedBookFile>` — 递归扫描 SAF 文件夹
- 伴生常量/方法：`MAX_FILES = 500`, `MAX_DEPTH = 8`, `SUPPORTED_EXTENSIONS = {txt, epub}`, `isSupportedBook(name)`, `isSkippableDirectory(name)`, `looksImported(fileName, existingTitles)`, `groupByDirectory(files, directoryOf)`

**功能描述：** SAF（存储访问框架）文件夹的递归扫描。使用 DocumentsContract 原始查询（一次查询拿整层）而非 androidx.documentfile（每个节点单独查），性能更好。广度优先，上限 500 文件、8 层深度。自动跳过隐藏目录和缓存目录。

---

### 6.3 BatchImportScheduler.kt

**类/接口/object：**
- `class BatchImportScheduler(...)` — 批量导入调度器

**功能描述：** 批量导入的调度与进度管理。将选中文件按顺序导入，支持进度回调和取消。

---

### 6.4 importer/lan/ — 局域网传输

| 文件 | 类型 | 功能描述 |
|------|------|----------|
| `LanBookServer.kt` | class | 局域网书籍分享 HTTP 服务器（接收上传） |
| `LanTransferService.kt` | class | 前台服务（保活、通知） |
| `HttpRequestParser.kt` | class | HTTP 请求解析器 |
| `MultipartReader.kt` | class | multipart/form-data 读取器 |
| `NetworkAddresses.kt` | object | 本机 IP 地址枚举 |
| `LanUploadNaming.kt` | object | 上传文件命名规则 |

**功能描述：** 局域网书籍传输功能。设备作为 HTTP 服务器，其他设备通过浏览器上传 TXT/EPUB 文件。包含完整的 HTTP 解析、multipart 读取、服务保活等。

---

## 七、core/vector/ — 向量数据库

### 7.1 VectorDb.java（final class）

**类/接口/object：**
- `public final class VectorDb` — 向量数据库门面

**常量/方法：**
- `public static final int EMBEDDING_DIMENSIONS = 1024` — 全局向量维度
- `public static BoxStore open(Context context)` — Android 运行时建库
- `public static BoxStore openAt(File directory)` — 桌面 JVM 建库（单测用）

**功能描述：** ObjectBox 向量数据库的建库门面。生成类（MyObjectBox 等）的触点全部收在 Java 文件中（因 Kotlin 先于 javac 编译，看不到注解处理器产物）。向量维度固定 1024，改动会触发 HNSW 索引重建。

---

### 7.2 VectorQueries.java（final class）

**类/接口/object：**
- `public final class VectorQueries` — 向量检索门面

**public 方法摘要：**
- `searchChunks(store, bookId, queryVector, topK, maxChapterIndex): List<ObjectWithScore<BookChunk>>` — 书内切片检索（含防剧透章节上限）
- `searchMemories(store, personaId, queryVector, topK): List<ObjectWithScore<MemoryEntry>>` — 角色记忆检索
- `searchMemories(store, personaId, queryVector, topK, bookId, maskId)` — 带书籍/面具过滤的记忆检索
- `searchMemories(store, personaId, queryVector, topK, bookId, maskId, scopeBookId, maxChapterIndex, maxCharOffset)` — 带检索范围边界的记忆检索
- `listMemories(store, personaId, offset, limit): List<MemoryEntry>` — 分页列出记忆（按时间倒序）
- `removeMemory(store, id)` — 删除单条记忆
- `removeMemoriesForPersona(store, personaId)` — 清空角色全部记忆
- `chaptersWithChunks(store, bookId): int[]` — 已有切片的章节集合
- `listChunks(store, bookId, maxChapterIndex): List<BookChunk>` — 列出章节范围内全部切片
- `countMemories(store, personaId): long` — 记忆条数
- `hasMemoryBatch(store, conversationId, sourceMessageId): boolean` — 某批记忆是否已写入
- `removeMemoriesForConversation(store, conversationId)` — 清除某会话的记忆
- `removeChunksForBook(store, bookId)` — 删书时清除全部切片
- `removeAllChunks(store)` — 清空全部切片（换 embedding 模型时）

**功能描述：** 向量检索的统一门面（Java 写，理由同 VectorDb）。返回余弦距离（越小越相近）。自适应扩大候选数（adaptiveSearch）直到凑够 topK 或穷尽，保证防剧透过滤不会把结果挤空。支持面具隔离（不同面具记忆不穿帮）。

---

### 7.3 BookChunk.java（@Entity）

**类/接口/object：**
- `@Entity public class BookChunk` — 书籍内容切片实体

**字段：**
- `long id` — 主键
- `long bookId` — 书籍 ID
- `int chapterIndex` — 章节索引
- `int chunkIndex` — 章内切片序号
- `int startCharOffset / endCharOffset` — UTF-16 原文范围
- `String text` — 切片文本
- `float[] embedding` — 向量（HNSW 索引，余弦距离）

**功能描述：** 书籍 RAG 切片的 ObjectBox 实体。纯 Java 写（无 ToOne/ToMany 关系），章节坐标与 Room 侧一致。

---

### 7.4 MemoryEntry.java（@Entity）

**类/接口/object：**
- `@Entity public class MemoryEntry` — 角色长期记忆实体

**字段：**
- `long id` — 主键
- `long personaId` — 角色 ID
- `Long bookId` — 书籍 ID（可空，null 为跨书全局记忆）
- `long conversationId` — 来源会话
- `long sourceMessageId` — 本批最后一条消息（幂等用）
- `long maskId` — 用户面具 ID（0 = 本人层）
- `int sourceChapterIndex / sourceCharOffset` — 产出时的检索范围边界
- `String summary` — 记忆摘要
- `String sourceType` — 来源类型（CHAT_SUMMARY / EVENT）
- `long createdAt` — 创建时间
- `float[] embedding` — 向量（HNSW 索引，余弦距离）

**功能描述：** 角色长期记忆的 ObjectBox 实体。按 personaId 隔离，bookId 可空区分本书记忆与跨书全局记忆。maskId 用于面具隔离（本人层永远参与召回，面具内经历只在同一面具下可见）。

---

### 7.5 ChapterChunker.kt（object）

**类/接口/object：**
- `data class ChapterChunk(text, startCharOffset, endCharOffset)` — 章节切片（含 UTF-16 范围）
- `object ChapterChunker` — 章节分块器

**public 方法摘要：**
- `chunk(text): List<String>` — 纯文本分块
- `chunkWithOffsets(text): List<ChapterChunk>` — 带偏移的分块
- 常量：`TARGET_CHARS = 480`, `MAX_CHARS = 640`

**功能描述：** 章节正文到 RAG 切片的纯函数分块器。段落为最小完整单元，贪心打包到 TARGET_CHARS（480）。超长段落先按句终符切句再打包，超长句硬切。打包永不跨段截断。支持 `chunk.split` JS hook 覆盖。

---

### 7.6 Embeddings.kt（object）

**类/接口/object：**
- `object Embeddings` — 嵌入向量工具

**public 方法摘要：**
- `conformToIndex(raw): FloatArray` — 规整到索引维度（MRL 截断/补零 + L2 归一化）

**功能描述：** 向量维度规整与归一化。超长按 MRL 截断，较短尾部补零，再做 L2 归一化。使不同维度的模型（384/768/1024）都能用于 ObjectBox 固定维度索引。

---

## 八、其他核心目录

### 8.1 core/di/ — 依赖注入模块

| 文件 | 类 | 功能描述 |
|------|-----|----------|
| `StorageModule.kt` | `object StorageModule` | 提供 Room 数据库、全部 DAO、DataStore Preferences 实例 |
| `VectorModule.kt` | `object VectorModule` | 提供 ObjectBox BoxStore（惰性构建） |
| `NetworkModule.kt` | `object NetworkModule` | 提供 OkHttpClient（含日志拦截器、超时配置） |
| `CoroutineModule.kt` | `object CoroutineModule` | 提供协程调度器 |

### 8.2 core/security/ — 加密存储

| 文件 | 类 | 功能描述 |
|------|-----|----------|
| `ApiKeyStore.kt` | `@Singleton class ApiKeyStore` | 基于 EncryptedSharedPreferences 的 API Key 加密存储（AES256_GCM） |

### 8.3 core/retrieval/ — 检索管线

| 文件 | 类/函数 | 功能描述 |
|------|---------|----------|
| `ReadingScope.kt` | `class ReadingScope`, `object ReadingScopeResolver` | 防剧透阅读范围（maxChapterIndex + maxCharOffset），所有检索/记忆统一使用 |
| `RetrievalPipeline.kt` | `class RetrievalPipeline`, `object RrfFusion`, `object Bm25LexicalRecall` | 混合检索管线：并行向量+词法召回 → RRF 融合 → 距离门控 → 范围门控 → 重排 → 邻居扩展 → 原文排序。含 BM25 词法实现（支持中英文） |

### 8.4 core/diag/ — API 诊断

| 文件 | 类 | 功能描述 |
|------|-----|----------|
| `ApiCallLog.kt` | `data class ApiCallLog` | API 调用日志条目 |
| `ApiCallLogStore.kt` | `@Singleton class ApiCallLogStore` | API 调用日志存储（用于诊断） |
| `ApiCallLogInterceptor.kt` | `class ApiCallLogInterceptor` | OkHttp 拦截器，记录 API 请求响应 |

### 8.5 core/epub/ — EPUB 解析

| 子目录 | 文件 | 功能描述 |
|--------|------|----------|
| `css/` | `CssTokenizer.kt` | CSS 词法分析器 |
| `css/` | `CssParser.kt` | CSS 语法解析器 |
| `css/` | `CssModel.kt` | CSS 模型（规则、选择器、声明等） |
| `css/` | `CssSelectorMatcher.kt` | CSS 选择器匹配器 |
| `css/` | `CssCascade.kt` | CSS 层叠计算 |
| `css/` | `CssColor.kt` | CSS 颜色解析 |
| `dom/` | `EpubDomModels.kt` | EPUB DOM 模型 |
| `dom/` | `EpubV9DomAdapter.kt` | v9 布局到 DOM 的适配器 |
| `style/` | `EpubStyleResolver.kt` | EPUB 样式解析器（CSS 应用到 DOM） |

### 8.6 其他

| 目录/文件 | 功能描述 |
|-----------|----------|
| `core/readium/ReadiumServices.kt` | Readium 工具封装 |
| `core/update/` | 应用更新（安装器、仓库、偏好设置） |
| `core/media/ImageApiSettingsStore.kt` | 图片生成 API 设置 |

---

## 九、核心类索引（按功能分类）

### 9.1 书籍库核心

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `LibraryRepository` | `library/LibraryRepository.kt` | 书籍/章节/目录/书签/阅读统计的统一 CRUD，正文文本读写，书籍生命周期管理 |
| `BookTextStore` | `library/BookTextStore.kt` | 从 text.mz blob 读取章节正文（单次 seek + LRU 缓存） |
| `BookTextWriter` | `library/BookTextWriter.kt` | 将多章正文写入 UTF-8 blob，返回字节范围 + 文本规范化 |
| `BookMediaStore` | `library/BookMediaStore.kt` | EPUB 行内图片的 sidecar 存储与读取（SVG→PNG、尺寸提取） |
| `BookLayoutStore` | `library/BookLayoutStore.kt` | EPUB 排版布局的持久化（DOM、样式表、字体、资源） |
| `BookCoverStore` | `library/BookCoverStore.kt` | 封面图片压缩保存（长边 1800px 限制） |
| `AnnotationRepository` | `library/AnnotationRepository.kt` | 批注（用户/AI）与讨论串回复的 CRUD |
| `NoteRepository` | `library/NoteRepository.kt` | 读书笔记（普通/剧情梗概）的 CRUD |
| `AudiobookRepository` | `library/AudiobookRepository.kt` | 有声书角色/剧本/分段的管理与状态流转 |
| `ShelfOrganizationRepository` | `library/ShelfOrganizationRepository.kt` | 书架分组与标签管理 |
| `IllustrationRepository` | `library/IllustrationRepository.kt` | AI 生成插图管理 |
| `AttachmentStore` | `library/AttachmentStore.kt` | 聊天消息附件（图片/文本文件）存储 |
| `BookQuoteLocator` | `library/BookQuoteLocator.kt` | 引文在书中的定位（精确匹配 + 归一化标点匹配） |

### 9.2 语音 / TTS

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `SystemTtsSpeaker` | `speech/SystemTtsSpeaker.kt` | 系统 TTS 门面，单段/批量朗读，引擎缓存 |
| `TtsSettingsStore` | `speech/TtsSettingsStore.kt` | TTS 全部配置（系统+AI 引擎、合成参数、有声书策略） |
| `TtsVoiceRepository` | `speech/TtsVoiceRepository.kt` | AI TTS 音色管理（含 JS hook 注入） |
| `SentenceSegmenter` | `speech/SentenceSegmenter.kt` | 句子/段落/章节粒度的文本切分（终止标点+次级停顿） |
| `SleepTimerPlanner` | `speech/SleepTimerPlanner.kt` | 听书睡眠定时状态机（分钟/章节/章末三种模式） |
| `SpeechCacheStore` | `speech/SpeechCacheStore.kt` | AI 语音缓存管理（容量预算、LRU 淘汰、按书统计） |
| `SpeechCacheSync` | `speech/SpeechCacheSync.kt` | 语音缓存 WebDAV 双向同步（内容哈希命名，无冲突） |
| `SpeechCacheSyncWorker` | `speech/SpeechCacheSyncWorker.kt` | 语音缓存自动同步 WorkManager 任务（仅 Wi-Fi） |

### 9.3 设置存储

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `ReaderSettingsRepository` | `datastore/ReaderSettingsRepository.kt` | 阅读与伴读全部设置的统一入口（50+ 字段） |
| `CustomReaderTheme` / `BookReaderTheme` | `datastore/CustomReaderTheme.kt` / `BookReaderTheme.kt` | 自定义主题 / 逐书主题数据模型 |
| `ReaderThemeSlots` | `datastore/ReaderThemeSlots.kt` | 日/夜双槽主题机制与扩展函数 |
| `ReaderTextReplacementRule` | `datastore/ReaderTextReplacementRule.kt` | 文本替换规则（含听书专用规则、版本指纹） |
| `ReaderSyntaxHighlighter` | `datastore/ReaderSyntaxHighlight.kt` | 成对符号/正则语法高亮引擎 |
| `ReaderFontLibrary` / `ReaderImageLibrary` | `datastore/ReaderFontLibrary.kt` / `ReaderImageLibrary.kt` | 字体库 / 图片库数据模型与序列化 |
| `ReaderFontImporter` / `ReaderImageImporter` | `datastore/ReaderFontImporter.kt` / `ReaderImageImporter.kt` | 字体 / 图片导入流程 |
| `BookEmbeddingSettingsStore` | `datastore/BookEmbeddingSettingsStore.kt` | 书籍向量索引启用设置 |
| `CompanionMemorySettings` | `datastore/CompanionMemorySettings.kt` | 伴读记忆范围开关（长期/跨书/跨书对话检索） |
| `CompanionAutonomySettings` | `datastore/CompanionAutonomySettings.kt` | AI 自主付费调用总闸（语音/生图/段评） |
| `GlobalPromptPresetStore` | `datastore/GlobalPromptPresetStore.kt` | 全局提示词预设管理（4 个注入位置） |
| `ProactiveAnnotationQuota` | `datastore/ProactiveAnnotationQuota.kt` | 随读段评日配额管理 |
| `UserMaskStore` | `datastore/UserMaskStore.kt` | 用户身份面具管理 |

### 9.4 数据库

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `MoReadDatabase` | `database/MoReadDatabase.kt` | Room 主数据库（22 个表，v22） |
| `BookDao` | `database/dao/BookDao.kt` | 书籍/章节/目录/书签/阅读统计 DAO |
| `AnnotationDao` | `database/dao/AnnotationDao.kt` | 批注与回复 DAO |
| `NoteDao` | `database/dao/NoteDao.kt` | 笔记 DAO |
| `AudiobookDao` | `database/dao/AudiobookDao.kt` | 有声书角色/分段/章节 DAO |
| `ShelfOrganizationDao` | `database/dao/ShelfOrganizationDao.kt` | 书架分组与标签 DAO |
| `ChatDao` | `database/dao/ChatDao.kt` | 会话与消息 DAO |
| `AiProviderDao` | `database/dao/AiProviderDao.kt` | AI 提供商/模型/角色分配 DAO |
| `PersonaDao` | `database/dao/PersonaDao.kt` | 角色卡 DAO |
| `DatabaseMigrations` | `database/DatabaseMigrations.kt` | 1→22 共 21 个数据库迁移 |

### 9.5 备份与恢复

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `BackupRepository` | `backup/BackupRepository.kt` | 备份恢复统一入口（WebDAV + 本地文件） |
| `BackupArchiveManager` | `backup/BackupArchiveManager.kt` | 备份 zip 生成与恢复（含安全校验、引导应用） |
| `WebDavClient` | `backup/WebDavClient.kt` | WebDAV 客户端（OkHttp 实现，PROPFIND/PUT/GET/DELETE） |
| `BackupSettingsStore` | `backup/BackupSettingsStore.kt` | WebDAV 备份设置存储（密码存加密存储） |
| `BackupRestoreBootstrap` | `backup/BackupArchiveManager.kt` | 应用启动前的恢复引导（Hilt/Room 创建前替换数据） |

### 9.6 书籍导入

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `BookImportGateway` | `importer/BookImportGateway.kt` | 导入网关接口（单本预览 / 批量直导 / 封面/目录回填） |
| `FolderScanner` | `importer/FolderScanner.kt` | SAF 文件夹递归扫描（广度优先、性能优化） |
| `BatchImportScheduler` | `importer/BatchImportScheduler.kt` | 批量导入调度 |
| `LanBookServer` | `importer/lan/LanBookServer.kt` | 局域网书籍分享 HTTP 服务器 |
| `LanTransferService` | `importer/lan/LanTransferService.kt` | 局域网传输前台服务 |

### 9.7 向量数据库 / RAG

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `VectorDb` | `vector/VectorDb.java` | ObjectBox 建库门面（Android/JVM），向量维度 1024 |
| `VectorQueries` | `vector/VectorQueries.java` | 向量检索统一门面（自适应候选、防剧透、面具隔离） |
| `BookChunk` | `vector/BookChunk.java` | 书籍切片实体（HNSW 余弦索引） |
| `MemoryEntry` | `vector/MemoryEntry.java` | 角色长期记忆实体（HNSW 余弦索引） |
| `ChapterChunker` | `vector/ChapterChunker.kt` | 章节正文→RAG 切片（段落为单元，句边界切分） |
| `Embeddings` | `vector/Embeddings.kt` | 向量维度规整与 L2 归一化 |
| `RetrievalPipeline` | `retrieval/RetrievalPipeline.kt` | 混合检索管线（向量+BM25 → RRF → 门控 → 重排 → 邻居扩展） |
| `ReadingScope` | `retrieval/ReadingScope.kt` | 防剧透阅读范围（统一边界，所有检索/记忆共用） |
| `Bm25LexicalRecall` | `retrieval/RetrievalPipeline.kt` | BM25 词法检索（中英文混合分词） |

### 9.8 安全 / 诊断 / 注入

| 类名 | 文件 | 核心职责 |
|------|------|----------|
| `ApiKeyStore` | `security/ApiKeyStore.kt` | 加密 API Key 存储（EncryptedSharedPreferences, AES256_GCM） |
| `ApiCallLogInterceptor` | `diag/ApiCallLogInterceptor.kt` | API 调用日志拦截器 |
| `StorageModule` | `di/StorageModule.kt` | Room/DataStore 的 Hilt 注入模块（21 个迁移） |
| `VectorModule` | `di/VectorModule.kt` | ObjectBox 的 Hilt 注入模块（惰性构建） |
| `NetworkModule` | `di/NetworkModule.kt` | OkHttpClient 的 Hilt 注入模块 |


