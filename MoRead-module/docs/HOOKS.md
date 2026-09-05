# MoRead 模块系统 — 钩子清单

> 最后更新：2026-09-05
> 用途：版本迭代时快速对齐钩子、避免重复添加、跟踪钩子实现进度

## 钩子命名规范

```
类别.功能.动作.类型

类别：
  text     — 文本处理
  listen   — 听书/TTS
  dialogue — 对白/有声书
  prompt   — AI 提示词
  tts      — TTS 引擎（原生）

类型（可选）：
  system   — System Prompt
  user     — User Prompt
```

---

## 钩子总表

| 状态 | 钩子名 | 类型 | 来源 | 说明 | 文件位置 |
|:---:|--------|------|------|------|----------|
| ✅ | `text.display` | 文本 | **我们加的** | 章节文本显示前，可修改显示文本 | `core/library/LibraryRepository.kt` → `readChapterText()` |
| ✅ | `text.preprocess` | 文本 | **我们加的** | TTS 朗读前文本预处理 | `ai/listen/ListenEngine.kt` → `buildScriptedQueue()` / `buildQueue()` |
| ✅ | `listen.sentence` | 听书 | 原生已有 | 句子断句，返回 JSON 数组 `[{start,end}]` | `core/speech/SentenceSegmenter.kt` → `segment()` |
| ✅ | `dialogue.segment` | 对白 | 原生已有 | 对白切分，返回 segments JSON | `ai/audiobook/DialogueRuleSegmenter.kt` → `segment()` |
| ✅ | `tts.synthesize` | TTS | 原生已有 | TTS 合成请求拦截 | `ai/client/OpenAiMediaClient.kt` |
| ✅ | `tts.voices` | TTS | 原生已有 | 自定义音色列表 | `ai/client/OpenAiMediaClient.kt` |
| ✅ | `prompt.audiobook.script.system` | 提示词 | **我们加的** | 有声书剧本生成 System Prompt | `ai/audiobook/AudiobookScriptAgent.kt` → `runAgentBatch()` |
| ✅ | `prompt.annotation.proactive.system` | 提示词 | **我们加的** | 随读段评 System Prompt | `ai/companion/ProactiveAnnotationService.kt` → `generateForCompletedChapter()` |
| ⏳ | `prompt.bookcover.system` | 提示词 | 计划中 | 书籍封面生成 System Prompt | `ai/media/BookCoverService.kt` |
| ⏳ | `prompt.memory.consolidate` | 提示词 | 计划中 | 记忆固化 System Prompt | `ai/memory/MemoryConsolidator.kt` |
| ⏳ | `prompt.reply.suggestion` | 提示词 | 计划中 | 回复建议 System Prompt | `ai/chat/ReplySuggestionService.kt` |
| ⏳ | `chunk.split` | 文本 | 原生已有 | 章节分块（向量嵌入用） | `ai/embedding/ChapterChunker.kt` |

**图例**：✅ 已实现  ⏳ 计划中  ❌ 未开始

---

## 钩子详细说明

### 1. text.display

**用途**：修改章节显示文本（阅读界面看到的内容）

**参数**：
```json
{
  "text": "原始章节文本",
  "bookId": 123,
  "chapterIndex": 0,
  "chapterTitle": "第一章 xxx"
}
```

**返回值**：`String`（修改后的文本），返回 `null` 表示不修改

**使用示例**：精校模块用它做显示文本的错别字修正

---

### 2. text.preprocess

**用途**：TTS 朗读前的文本预处理

**参数**：
```json
{
  "text": "待朗读文本",
  "roleName": "旁白/角色名",
  "engine": "system 或 ai"
}
```

**返回值**：`String`（修改后的文本），返回 `null` 表示不修改

**使用示例**：精校模块用它做 TTS 朗读文本的标点规范化

---

### 3. listen.sentence

**用途**：自定义句子断句

**参数**：
```json
{
  "body": "章节正文",
  "maxChars": 96
}
```

**返回值**：JSON 字符串
```json
[{"start": 0, "end": 48}, {"start": 48, "end": 96}]
```

返回 `null` 或空数组 → 使用原生断句

---

### 4. dialogue.segment

**用途**：智能对白切分（区分旁白和对话）

**参数**：
```json
{
  "text": "章节文本",
  "bookId": 123,
  "chapterIndex": 0
}
```

**返回值**：JSON 字符串
```json
[
  {"start": 0, "end": 20, "role": "旁白", "kind": "NARRATION", "confidence": 0.95},
  {"start": 20, "end": 50, "role": "张三", "kind": "DIALOGUE", "confidence": 0.88}
]
```

返回 `null` → 使用原生对白切分

---

### 5. tts.synthesize

**用途**：接管 TTS 合成请求，转发到自定义端点

**参数**：`text`, `voiceId`, `speed`, `format` 等

**返回值**：音频数据（base64 或 URL），返回 `null` 走原生 TTS

---

### 6. tts.voices

**用途**：自定义音色列表

**参数**：无

**返回值**：JSON 数组（音色列表），返回 `null` 用原生列表

---

### 7. prompt.audiobook.script.system

**用途**：自定义有声书剧本生成的 System Prompt

**参数**：
```json
{
  "default": "默认的 system prompt 全文",
  "bookId": 123,
  "chapterTitle": "章节标题",
  "roleCount": 5
}
```

**返回值**：`String`（自定义的 system prompt），返回 `null` 用默认

**设计原则**：模块可以基于 `default` 修改，也可以完全重写

---

### 8. prompt.annotation.proactive.system

**用途**：自定义随读段评的 System Prompt

**参数**：
```json
{
  "default": "默认的 system prompt 全文",
  "bookId": 123,
  "chapterIndex": 0,
  "maxAnnotations": 2
}
```

**返回值**：`String`（自定义的 system prompt），返回 `null` 用默认

---

## 版本迭代检查清单

作者版本升级后，按以下顺序检查：

1. [ ] `text.display` 钩子 → `LibraryRepository.readChapterText()` 还在吗？
2. [ ] `text.preprocess` 钩子 → `ListenEngine.buildScriptedQueue()` / `buildQueue()` 还在吗？
3. [ ] `prompt.audiobook.script.system` → `AudiobookScriptAgent.runAgentBatch()` 还在吗？
4. [ ] `prompt.annotation.proactive.system` → `ProactiveAnnotationService.generateForCompletedChapter()` 还在吗？
5. [ ] `dialogue.segment` 的 `bookId` 参数 → `DialogueRuleSegmenter.segment()` 签名变了吗？
6. [ ] 原生钩子（`listen.sentence` / `tts.synthesize` / `tts.voices` / `chunk.split`）还在吗？

如果某个钩子的函数签名变了或者位置移了，更新对应文件中的钩子调用即可。
