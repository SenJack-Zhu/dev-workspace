# MoRead 模块系统

> 无需 root 的 "LSPosed 式" 钩子框架，通过 JavaScript 模块自定义 MoRead 功能。

## 目录结构

```
MoRead-module/
├── app/                          # App 源码
│   └── src/main/java/com/mozhi/reader/
│       ├── modules/              # 模块系统核心（HookRegistry, ModuleLoader, JsEngine）
│       └── ...                   # 其余原生代码
├── modules/                      # 模块文件（.mrm 包 + 源码 + 清单）
├── docs/                         # 文档
│   ├── README.md                 # 本文件
│   ├── HOOKS.md                  # 钩子清单
│   ├── ROADMAP.md                # 需求计划与路线图
│   ├── ERRORS.md                 # 编译错误知识库（推送前必读）
│   ├── MoRead-代码地图-总索引.md
│   ├── MoRead-core-api-reference.md
│   ├── MoRead-ai-api-reference.md
│   └── MoRead-feature-api-reference.md
└── ...
```

## 核心概念

### 什么是模块？

模块是一个 `.mrm` 格式的压缩包（本质是 ZIP），包含：
- `manifest.json` — 模块清单（名称、版本、设置项）
- `*.js` — 模块代码（JavaScript）

模块通过注册**钩子**来介入 App 的运行流程，钩子触发时模块代码被执行，可以修改数据、替换行为、新增功能。

### 什么是钩子？

钩子是 App 预留的"可插拔点"。模块在钩子上注册回调，当 App 运行到该位置时，会调用所有注册了这个钩子的模块。

返回 `null` 表示"不做修改，用默认的"，返回具体值表示"用我的"。

### 核心理念

- **不修改原生代码也能用** — 原生就有的钩子（`listen.sentence`, `dialogue.segment`, `tts.synthesize` 等）直接用
- **想扩展就加钩子** — 需要新的定制点时，在原生代码里加一行 `HookPoints.call(...)`
- **开关自由** — 每个模块独立开关，关了就完全不影响
- **数据安全** — 模块运行在 JS 沙箱里，只能通过暴露的 API 和原生交互

## 快速开始

### 安装模块

1. 打开 MoRead → 设置 → 模块管理
2. 点击「导入模块包」
3. 选择 `.mrm` 文件
4. 模块自动加载，在列表中找到它，开启即可

### 开发模块

1. 创建一个文件夹，包含 `manifest.json` 和你的 JS 文件
2. 用 `MoRead.hook("钩子名", function(params) { ... })` 注册钩子
3. 打包成 ZIP，改后缀为 `.mrm`
4. 导入测试

### manifest.json 格式

```json
{
  "name": "module-name",
  "displayName": "模块显示名",
  "version": "1.0.0",
  "author": "作者",
  "description": "模块描述",
  "settings": [
    {
      "key": "settingKey",
      "label": "设置项显示名称",
      "type": "bool|string|select|int",
      "default": "默认值",
      "options": "选项1|选项2|选项3"
    }
  ]
}
```

### 模块 API

```javascript
// 注册钩子
MoRead.hook("hook.name", function(params) {
    return "modified result";  // 返回 null 表示不修改
});

// 读取配置
var value = MoRead.configGet("settingKey", "defaultValue");

// 写日志
MoRead.log("message");

// 本地存储（持久化）
MoRead.storageSet("key", "value");
var v = MoRead.storageGet("key", "default");

// HTTP 请求
var resp = MoRead.httpPost(url, body, contentType, headers);
// resp.ok, resp.status, resp.body

// AI 对话（复用原生配置的所有供应商）
var reply = MoRead.aiChat("系统提示词", "用户消息", "CHEAP");
// 多轮对话
var reply = MoRead.aiChatJSON('[{"role":"system","content":"..."},{"role":"user","content":"..."}]', "CHEAP");

// AI 生图（复用原生生图配置，自动转换提示词格式）
var imgBase64 = MoRead.aiGenerateImage("提示词", 1, "1024x1024");
var imgsJson = MoRead.aiGenerateImages("提示词", 4, "1536x1024");
```

## 内置模块

| 模块 | 版本 | 描述 | 钩子 |
|------|:---:|------|------|
| **文本精校** (text-proofread) | v1.1.1 | 标点规范化、错别字替换、自定义正则替换、空白清理 | `text.display`, `text.preprocess` |
| **TTS 增强** (tts-enhance) | v1.1.0 | 自定义 TTS 端点（OpenAI/万能转发器）、音色列表、断句规则 | `tts.synthesize`, `tts.voices`, `listen.sentence` |

内置模块不可删除，重启/重新加载后自动恢复。

## 可选模块

| 模块 | 版本 | 描述 | 钩子 |
|------|:---:|------|------|
| **智能文本理解** (smart-text) | v0.3.0 | AI 辅助自增长知识库，智能区分对话与专有名词，越读越准（支持原生 AI） | `dialogue.segment` |
| **提示词管理器** (prompt-manager) | v0.1.0 | 集中管理所有 AI 提示词，支持酒馆角色卡导入 | `prompt.audiobook.script.system`, `prompt.annotation.proactive.system` |

可选模块需要手动导入，不内置。

## 钩子总览

完整钩子清单见 [HOOKS.md](./HOOKS.md)

### 原生钩子（作者已有，直接用）

- `listen.sentence` — 句子断句
- `dialogue.segment` — 对白切分
- `tts.synthesize` — TTS 合成
- `tts.voices` — 音色列表
- `chunk.split` — 章节分块

### 我们新增的钩子

- `text.display` — 显示文本修改
- `text.preprocess` — TTS 文本预处理
- `prompt.audiobook.script.system` — 有声书剧本 prompt
- `prompt.annotation.proactive.system` — 随读段评 prompt

## 文档索引

| 文档 | 说明 |
|------|------|
| [HOOKS.md](./HOOKS.md) | 钩子完整清单：参数、返回值、文件位置、版本检查清单 |
| [ROADMAP.md](./ROADMAP.md) | 需求计划与路线图：进度跟踪、优先级、迭代策略 |
| [MoRead-代码地图-总索引.md](./MoRead-代码地图-总索引.md) | 项目架构全景、核心类速查、关键数据流 |
| [MoRead-core-api-reference.md](./MoRead-core-api-reference.md) | core 层 API 参考（~100 个文件） |
| [MoRead-ai-api-reference.md](./MoRead-ai-api-reference.md) | ai 层 API 参考（~65 个文件） |
| [MoRead-feature-api-reference.md](./MoRead-feature-api-reference.md) | feature 层架构参考 |

## 版本升级指南

作者迭代版本后，按以下步骤重新应用模块系统：

1. 对照 [HOOKS.md](./HOOKS.md) 中的「版本迭代检查清单」逐个确认钩子
2. 修复位置变动或签名变化的钩子
3. 编译验证
4. 更新相关文档

详细流程见 [ROADMAP.md](./ROADMAP.md) 中的「版本迭代策略」。
