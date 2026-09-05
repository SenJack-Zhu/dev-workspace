# MoRead 代码地图 - 总索引

> 项目代码全景速查手册，覆盖 core / ai / feature / modules 四层架构。
> 下次加钩子、改功能，先查本文档定位文件，再去看具体实现。

---

## 文档清单

| 文档 | 覆盖范围 | 文件数 | 链接 |
|------|----------|--------|------|
| Core 层 API 参考 | core/ 所有子目录（library, speech, datastore, database, backup, importer, vector 等） | ~100 | [MoRead-core-api-reference.md](computer:///workspace/MoRead-core-api-reference.md) |
| AI 层 API 参考 | ai/ 所有子目录（listen, audiobook, agent, chat, client, persona, memory 等） | ~65 | [MoRead-ai-api-reference.md](computer:///workspace/MoRead-ai-api-reference.md) |
| Feature 层架构参考 | feature/ 9 个模块（reader, listen, importer, bookshelf, settings 等） | ~120 | [MoRead-feature-api-reference.md](computer:///workspace/MoRead-feature-api-reference.md) |

---

## 项目架构总览

```
MoRead (Android - Kotlin + Jetpack Compose + Hilt)
│
├── modules/           ← 模块系统（我们自己加的）
│   ├── HookRegistry       钩子注册与调用
│   ├── HookPoints         静态钩子入口（兼容旧代码）
│   ├── JsEngine           Rhino JS 执行引擎
│   ├── ModuleApi          JS ↔ Kotlin 桥接 API
│   ├── ModuleLoader       模块加载与卸载
│   ├── ModuleImporter     .mrm 包导入/导出
│   └── ModulePackageInfo  模块包信息数据类
│
├── core/              ← 核心业务层（Repository + Data + Domain）
│   ├── library/           书籍库 / 文本 / 批注 / 书架
│   ├── speech/            TTS / 句子切分 / 语音缓存
│   ├── datastore/         设置项 / 主题 / 字体 / 替换规则
│   ├── database/          Room 数据库 + DAO + Entity
│   ├── backup/            备份 / WebDAV
│   ├── importer/          书籍导入 / 局域网传输
│   ├── vector/            向量数据库 / RAG
│   ├── epub/              EPUB CSS 解析 / 样式
│   ├── di/                Hilt 依赖注入模块
│   ├── security/          API Key 安全存储
│   ├── diag/              API 调用日志
│   ├── retrieval/         阅读上下文检索管线
│   ├── readium/           Readium 服务封装
│   ├── update/            应用更新
│   └── media/             图片 API 设置
│
├── ai/                ← AI 功能层（LLM + TTS + Agent + 记忆）
│   ├── listen/            听书引擎（核心）
│   ├── audiobook/         有声书制作管线
│   ├── agent/             AI Agent 循环 + 工具集
│   ├── chat/              AI 聊天 / 回复建议
│   ├── client/            AI API 客户端（多厂商）
│   ├── persona/           角色人设 / 卡牌解析
│   ├── memory/            记忆系统 / 画像 / 前情提要
│   ├── companion/         陪伴功能 / 主动批注
│   ├── embedding/         书籍向量化管线
│   ├── media/             图片生成 / 封面
│   ├── prompt/            提示词构建 / 注入
│   ├── provider/          AI 提供商管理
│   └── search/            网页搜索
│
├── feature/           ← UI + ViewModel 层（MVI 模式）
│   ├── reader/            阅读器（最复杂，含排版引擎）
│   ├── listen/            听书播放器
│   ├── importer/          导入向导
│   ├── bookshelf/         书架
│   ├── settings/          设置页（15 个 ViewModel）
│   ├── companion/         陪伴界面
│   ├── bookdetail/        书籍详情
│   └── stats/             阅读统计
│
├── ui/                ← 通用 UI 组件
│   ├── components/        通用组件（按钮、卡片、菜单等）
│   └── theme/             主题 / 设计令牌 / 字体
│
├── MoReadApplication      Application 入口（@HiltAndroidApp）
└── MainActivity           主 Activity（ComponentActivity）
```

---

## 核心类速查（按功能）

### 1. 书籍库与文本

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `LibraryRepository` | core/library/LibraryRepository.kt | 书籍库总入口，增删改查、章节读取 |
| `BookTextStore` | core/library/BookTextStore.kt | 章节文本存储（按字节偏移读取） |
| `BookTextWriter` | core/library/BookTextWriter.kt | 文本写入 |
| `AnnotationRepository` | core/library/AnnotationRepository.kt | 批注管理 |
| `NoteRepository` | core/library/NoteRepository.kt | 笔记管理 |
| `ShelfOrganizationRepository` | core/library/ShelfOrganizationRepository.kt | 书架分组/标签 |
| `AudiobookRepository` | core/library/AudiobookRepository.kt | 有声书数据管理 |

### 2. 语音与 TTS

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `ListenEngine` | ai/listen/ListenEngine.kt | **听书引擎核心**：逐句朗读、预取、进度追踪 |
| `SentenceSegmenter` | core/speech/SentenceSegmenter.kt | 句子切分/断句 |
| `SystemTtsSpeaker` | core/speech/SystemTtsSpeaker.kt | 系统 TTS 封装 |
| `TtsSettingsStore` | core/speech/TtsSettingsStore.kt | TTS 设置存储 |
| `TtsVoiceRepository` | core/speech/TtsVoiceRepository.kt | 音色库管理 |
| `SpeechCacheStore` | core/speech/SpeechCacheStore.kt | 语音缓存 |
| `SleepTimerPlanner` | core/speech/SleepTimerPlanner.kt | 睡眠定时 |
| `ListenService` | ai/listen/ListenService.kt | 听书前台服务 |

### 3. 设置存储

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `ReaderSettingsRepository` | core/datastore/ReaderSettingsRepository.kt | 阅读器设置总入口 |
| `ReaderTextReplacementRule` | core/datastore/ReaderTextReplacementRule.kt | 文本替换规则（`purifyForListening`） |
| `BookReaderTheme` | core/datastore/BookReaderTheme.kt | 阅读器主题 |
| `ReaderFontLibrary` | core/datastore/ReaderFontLibrary.kt | 字体库 |
| `ReaderImageLibrary` | core/datastore/ReaderImageLibrary.kt | 图片库 |
| `CompanionAutonomySettings` | core/datastore/CompanionAutonomySettings.kt | 陪伴自主权设置 |
| `CompanionMemorySettings` | core/datastore/CompanionMemorySettings.kt | 记忆设置 |

### 4. 有声书制作

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `AudiobookProducer` | ai/audiobook/AudiobookProducer.kt | 有声书合成执行器 |
| `AudiobookScriptAgent` | ai/audiobook/AudiobookScriptAgent.kt | 剧本生成（AI） |
| `DialogueRuleSegmenter` | ai/audiobook/DialogueRuleSegmenter.kt | 对话规则切分（本地） |
| `AudiobookRoleExtractor` | ai/audiobook/AudiobookRoleExtractor.kt | 角色提取 |
| `VoiceAssignmentParser` | ai/audiobook/VoiceAssignmentParser.kt | 音色分配解析 |
| `AudiobookProductionWorker` | ai/audiobook/AudiobookProductionWorker.kt | 后台制作 Worker |

### 5. AI Agent 与聊天

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `AgentLoop` | ai/agent/AgentLoop.kt | Agent 主循环（工具调用 + 持久化） |
| `ReaderToolset` | ai/agent/ReaderToolset.kt | 阅读侧 14 个工具 |
| `AiChatRepository` | ai/chat/AiChatRepository.kt | 聊天记录管理 |
| `CompanionContextBuilder` | ai/prompt/CompanionContextBuilder.kt | 陪伴上下文构建 |
| `GlobalPromptInjector` | ai/prompt/GlobalPromptInjector.kt | 全局提示词注入 |

### 6. AI 客户端

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `AiClientFactory` | ai/client/AiClientFactory.kt | 客户端工厂 |
| `ChatApiClient` | ai/client/ChatApiClient.kt | 统一聊天 API 接口 |
| `OpenAiCompatClient` | ai/client/OpenAiCompatClient.kt | OpenAI 兼容协议 |
| `ClaudeClient` | ai/client/ClaudeClient.kt | Claude API |
| `GeminiClient` | ai/client/GeminiClient.kt | Gemini API |
| `OpenAiResponsesClient` | ai/client/OpenAiResponsesClient.kt | OpenAI Responses API |
| `AiProviderRepository` | ai/provider/AiProviderRepository.kt | 提供商配置管理 |

### 7. 记忆系统

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `MemoryConsolidator` | ai/memory/MemoryConsolidator.kt | 记忆固化核心 |
| `RollingSummarizer` | ai/memory/RollingSummarizer.kt | 滚动摘要 / 前情提要 |
| `PersonaMemoryRepository` | ai/memory/PersonaMemoryRepository.kt | 角色记忆存储 |
| `UserProfileParser` | ai/memory/UserProfileParser.kt | 用户画像解析 |

### 8. 阅读器排版引擎

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `ReaderContentController` | feature/reader/engine/ReaderContentController.kt | 阅读器内容控制器（三章窗口） |
| `ChapterTypesetter` | feature/reader/engine/ChapterTypesetter.kt | 纯文本排版 |
| `EpubTypesetterV2` | feature/reader/engine/epub/EpubTypesetterV2.kt | EPUB V2 排版入口 |
| `EpubBoxTree` | feature/reader/engine/epub/EpubBoxTree.kt | 盒树构建 |
| `EpubBlockLayout` | feature/reader/engine/epub/EpubBlockLayout.kt | 块级布局 |
| `EpubPageBuilder` | feature/reader/engine/epub/EpubPageBuilder.kt | 分页构建 |
| `PageBitmapRenderer` | feature/reader/render/PageBitmapRenderer.kt | 页面位图渲染 |
| `ReaderViewModel` | feature/reader/ReaderViewModel.kt | 阅读器 ViewModel |

### 9. 导入系统

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `ImportCoordinator` | feature/importer/ImportCoordinator.kt | 导入协调器 |
| `BookImportGateway` | core/importer/BookImportGateway.kt | 导入网关 |
| `TxtChapterSplitter` | feature/importer/TxtChapterSplitter.kt | TXT 分章 |
| `EpubTextExtractor` | feature/importer/EpubTextExtractor.kt | EPUB 文本提取 |
| `FolderScanner` | core/importer/FolderScanner.kt | 文件夹扫描 |

### 10. 模块系统（我们的代码）

| 类名 | 文件路径 | 功能 |
|------|----------|------|
| `HookRegistry` | modules/HookRegistry.kt | 钩子注册与调用（DI 注入用） |
| `HookPoints` | modules/HookPoints.kt | 静态钩子入口（旧代码兼容用） |
| `JsEngine` | modules/JsEngine.kt | Rhino JS 执行引擎封装 |
| `ModuleApi` | modules/ModuleApi.kt | JS 侧 API（MoRead.log / MoRead.hook 等） |
| `ModuleLoader` | modules/ModuleLoader.kt | 模块加载/卸载/热重载 |
| `ModuleImporter` | modules/ModuleImporter.kt | .mrm 包导入/导出 |
| `ModulePackageInfo` | modules/ModulePackageInfo.kt | 模块清单数据类 |

---

## 已开放的钩子点

| 钩子名 | 作用时机 | 返回值 | 埋点位置 |
|--------|----------|--------|----------|
| `text.display` | 章节文本显示前 | 修改后的文本 | `LibraryRepository.readChapterText()` |
| `text.preprocess` | TTS 朗读前 | 修改后的文本 | `ListenEngine.buildScriptedQueue()` / `buildQueue()` |
| `listen.sentence` | 句子断句时 | JSON `[{start,end}]` | `SentenceSegmenter.segment()` |

---

## 潜在钩子候选点（未来可加）

> 按"改动收益/复杂度"排序，优先加收益高、改动小的。

### 高优先级（容易加且实用）

| 候选钩子 | 埋点位置 | 用途举例 |
|----------|----------|----------|
| `tts.speak.before` | `ListenEngine` 单句朗读前 | 替换单句文本、动态调整语速 |
| `book.open` | `LibraryRepository.openBook()` | 打开书籍时触发自定义动作 |
| `chapter.end` | `ListenEngine` 章节结束时 | 打卡、统计、弹出自定义内容 |
| `text.replace.custom` | `purifyForListening()` | 自定义文本替换规则（扩展原生替换） |
| `search.query` | `BookTextSearch` | 搜索查询拦截/改写 |

### 中优先级（有一定复杂度但价值高）

| 候选钩子 | 埋点位置 | 用途举例 |
|----------|----------|----------|
| `reader.page.turn` | `ReaderViewModel` 翻页时 | 翻页动画、自定义事件统计 |
| `annotation.create` | `AnnotationRepository` | 创建批注时触发（同步、AI 分析） |
| `book.import` | `ImportCoordinator` 导入后 | 导入后处理（自动打标签、分类） |
| `setting.change` | `ReaderSettingsRepository` | 设置变更联动模块配置 |

### 低优先级（复杂但扩展性强）

| 候选钩子 | 埋点位置 | 用途举例 |
|----------|----------|----------|
| `ui.drawer.item` | 侧边栏 | 注入自定义菜单项 |
| `reader.selection.menu` | 文本选择菜单 | 注入自定义操作项 |
| `ai.chat.message` | `AiChatRepository` | 拦截/修改 AI 对话 |
| `audiobook.produce` | `AudiobookProducer` | 有声书制作流程干预 |

---

## 数据流关键路径

### 听书朗读流程

```
用户点击播放
  → ListenEngine.play()
    → 加载章节文本 (libraryRepository.readChapterText)
    → 文本净化 (purifyForListening)
    → [钩子: text.preprocess]
    → 句子切分 (SentenceSegmenter.segment)
        → [钩子: listen.sentence]
    → 逐句送入 TTS 引擎
    → 进度实时回写
```

### 文本显示流程

```
用户翻页/打开章节
  → LibraryRepository.readChapterText()
    → [钩子: text.display]
    → 返回给 ReaderViewModel
    → ChapterTypesetter / EpubTypesetterV2 排版
    → PageBitmapRenderer 渲染
    → 显示
```

### 模块加载流程

```
App 启动 / 模块开关切换
  → ModuleLoader.loadAll()
    → 扫描内部模块目录
    → 读取 manifest.json
    → 初始化 JsEngine
    → 注入 ModuleApi (MoRead 对象)
    → 执行模块 JS 代码
    → 模块注册钩子 (MoRead.hook)
    → 钩子存入 HookRegistry
```

---

*文档生成时间：2026-09-05*
*基于 MoRead-module 分支代码快照*
