# 开发对话总结与工作准则

> 本文档记录开发过程中的关键决策、工作流程和用户强调的重要规则。
> 当 AI 助手上下文丢失时，读取此文档可快速恢复工作状态。
> 最后更新：2026-09-06

---

## 📌 用户强调的重要规则（必须遵守）

### 1. 版本控制（Tag）
- **不要自动打 tag**，只有用户明确说"打 tag"或"做版本控制"时才做
- **编译成功后才能打 tag**，不确定编译是否通过时不打
- 打 tag 前先确认 CI 构建结果

### 2. 报错排查
- 用户说"报错了" = **GitHub Actions (CI) 报错了**，不是本地编译
- **不需要本地编译**，直接去请求 GitHub Actions 日志排查
- 用 `curl` + GitHub API token 拉取最新 run 的日志
- token: `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`

### 3. 代码推送
- **推送前先确认**，用户说"可以推了"再推
- 小改动、中间状态先本地提交不推送
- Actions 额度不是无限的，没必要的编译能省则省
- 推送完不需要等结果，失败了用户会说
- **文档类改动**先本地提交，攒着等下次代码改动一起推送，避免纯文档推送也触发 CI 编译

### 4. 错误文档
- **每次推送前必须过一遍 `docs/ERRORS.md`**
- 按检查清单逐条核对：语法 → 类型 → 钩子 → 资源
- 新错误修复后要补充到 ERRORS.md

### 5. 仓库范围
- 只动 `MoRead-module/` 目录
- **不要动 `NativeTavern-O/` 和其他二级目录**

---

## 🏗️ 项目结构速览

```
dev-workspace/
├── MoRead-module/          ← 我们的工作目录（Android 阅读器 + 模块系统）
│   ├── app/
│   │   └── src/main/
│   │       ├── java/com/mozhi/reader/
│   │       │   ├── modules/           ← 模块系统核心
│   │       │   │   ├── ModuleApi.kt       ← JS ↔ Kotlin 桥接 API
│   │       │   │   ├── ModuleLoader.kt    ← 模块加载器 + 内置模块
│   │       │   │   ├── ModuleImporter.kt  ← .mrm 包导入/导出
│   │       │   │   ├── HookRegistry.kt    ← 钩子注册与调用
│   │       │   │   └── JsEngine.kt        ← Rhino JS 引擎封装
│   │       │   └── feature/settings/
│   │       │       ├── ModuleSettingsScreen.kt   ← 模块管理 UI
│   │       │       └── ModuleSettingsViewModel.kt ← 模块管理 VM
│   │       └── assets/modules/        ← 内置模块（assets 中）
│   │           ├── text-proofread/     ← 文本精校模块
│   │           ├── tts-enhance/        ← TTS 增强模块
│   │           └── smart-text/         ← 智能文本理解模块
│   └── docs/
│       ├── ERRORS.md               ← ⚠️ 编译错误知识库（必读）
│       ├── HOOKS.md                ← 钩子系统文档
│       ├── MoRead-core-api-reference.md
│       └── README.md
└── NativeTavern-O/             ← 不要动！
```

---

## 🔧 模块系统核心概念

### 架构概览
- **Rhino JS 引擎**：运行模块 JavaScript 代码
- **钩子系统（Hook Registry）**：JS 模块注册钩子，Kotlin 原生代码在特定点调用钩子实现自定义
- **ModuleApi**：JS 侧调用原生能力的桥梁（config、storage、AI、HTTP、log 等）
- **ModuleLoader**：扫描并加载 .js 模块文件，处理内置模块恢复
- **ModuleImporter**：处理 .mrm（ZIP）模块包的导入导出

### 配置系统
- 全局配置存在 `modules/config.json`（内部存储）
- `ModuleApi` 和 `ModuleImporter` 共用同一份配置（通过 `moduleApi.configGet/Set`）
- `ModuleApi.configSet()` 会自动保存到文件（`saveConfig()`）
- 模块设置的开关状态存在 `modules/settings.json`（由 `ModuleLoader` 管理）

### 内置模块
- 在 `assets/modules/` 下，每次 `loadAll()` 时会恢复到内部存储
- 用户无法删除内置模块（只能禁用）
- 当前内置模块：`text-proofread`、`tts-enhance`、`smart-text`

### 模块设置 UI
- 模块可以在 `manifest.json` 的 `settings` 数组中声明配置项
- 支持类型：`string`、`password`、`bool`、`select`、`slider`
- 设置弹窗有两个 Tab：设置 / 日志
- 保存设置后自动关闭窗口 + Toast 提示

---

## 📝 近期开发记录

### v0.2.0 模块系统增强（commit f4d448f，编译失败，后被 3bf0174 修复）

**已完成的功能：**
1. ✅ **配置持久化修复** — ModuleApi.configSet() 自动调用 saveConfig()，ModuleImporter 复用 ModuleApi 的配置读写
2. ✅ **Toast 提示 + 自动关窗** — 保存设置后弹出 Toast 并自动关闭设置窗口
3. ✅ **模块日志面板** — 模块设置弹窗增加 Tab 切换（设置/日志），可查看该模块专属日志
4. ✅ **smart-text 内置化** — 加入 `ModuleLoader.builtInPackages` 列表，assets 中添加模块文件
5. ✅ **HookRegistry 调用日志** — `call()` 方法中记录被哪个模块处理了
6. ✅ **校对模块默认值修复** — JS 中 `isEnabled()` 增加 default 参数，与 manifest 对齐

**修复的编译错误（commit 3bf0174）：**
1. ModuleSettingsScreen.kt 设置弹窗括号不匹配 + 日志 tab 内容缺失
2. ModuleImporter.kt `mergeConfig()` 函数缺少 `packageName` 参数

**配置隔离（commit 92bc74a，本地未推送）：**
1. ModuleApi: 增加 `currentPackageName` ThreadLocal，config/storage 自动加 `包名:` 前缀
2. ModuleLoader: 加载模块时设置当前包名
3. ModuleImporter: 配置读写显式传包名
4. ModuleSettingsViewModel: 设置 UI 传包名
5. 向后兼容：读取时带前缀找不到降级找旧 key

---

## 🐛 常见错误速查（完整列表见 ERRORS.md）

| 错误 | 原因 | 修复 |
|------|------|------|
| `Unresolved reference: Spacer/width` 等 | 缺少 Compose import | 检查 import，modifier 扩展也要检查 |
| `Syntax error: Expecting an argument` | 变量声明写到函数参数里了 | 把 val/var 移到函数外面 |
| `NativeError is package-private` | Rhino 的 NativeError 是包内可见 | 用 `JavaScriptException.lineNumber()` 和 `sourceName()` |
| Rhino 正则 `Invalid quantifier ?` | 用了后行断言 `(?<=...)` | Rhino 不支持，改用占位符替换法 |
| `mergeConfig` 报 `packageName` 未定义 | 函数参数漏了 | `mergeConfig(packageName, packageConfig)` |

---

## 🔄 标准工作流程

### 改代码 → 提交 → 推送
```
1. 改代码
2. 过 ERRORS.md 检查清单
3. git diff 自查一遍
4. 本地提交（不推送）
5. 跟用户确认："要推送吗？"
6. 用户说推 → git push
7. 不等结果，失败了用户会说
```

### 报错排查
```
1. 用户说"报错了" = CI 报错
2. 用 GitHub API 拉最新 run 的状态和日志
3. 定位错误原因
4. 修复
5. 本地提交
6. 确认后推送
7. 新错误补充到 ERRORS.md
```

---

## 🔑 认证信息

- **GitHub 仓库**：https://github.com/SenJack-Zhu/dev-workspace.git
- **GitHub PAT**：`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`
- **当前分支**：main

---

## 🏷️ 命名规范（已确认）

### 三层结构

| 层级 | 中文名称 | 英文（代码用） | 说明 |
|------|---------|---------------|------|
| 第一层（框架） | **模块引擎** | ModuleEngine | 底层运行框架：加载器、钩子系统、JS 引擎、API 桥接、导入导出 |
| 第二层（包） | **模块** | Module | 一个可安装/卸载/启停的独立单元（目录 + manifest + 若干模块单元） |
| 第三层（功能） | **模块单元** | ModuleUnit | 单个 .js 文件，注册一组钩子，实现具体功能 |

### 记忆方式
都带"模块"关键字，层级关系清晰：
模块引擎 → 模块 → 模块单元

### 说明
- UI 上用户主要接触"模块"（第二层），所以界面叫"模块管理"没问题
- "模块单元"主要是内部概念，用户一般感知不到（大多数模块只有一个单元）
- 启用/禁用、导入/导出、删除，都是按"模块"（包）粒度操作
- 钩子（Hook）是扩展点，不是层级概念，模块单元通过注册钩子来扩展功能

---

## 🗺️ 配置系统演进规划（已确认，待实施）

### 当前状态（前缀方案，已实现未推送）
config.json 和 storage.json 是扁平 key-value，用 `包名:key` 前缀做隔离。

### 目标架构（分两步走）

**第一阶段：JSON 块结构（内部重构，对外 API 不变）**

`config.json` 从扁平改为嵌套：
```json
{
  "text-proofread": { "enableDisplay": "true", "enableProofread": "true" },
  "smart-text": { "aiMode": "off", "enableDialogueSegment": "true" },
  "_global": { "modulesEnabled": true, "packageEnabled": {} }
}
```
- JS API 不变（`MoRead.configGet("key")` 自动进当前模块的块）
- 全局配置放 `_global` 块
- 向后兼容：迁移时自动把扁平 key 归到对应模块的块里

**第二阶段：模块目录独立配置文件**

```
modules/
├── _global/
│   └── config.json         ← 全局配置（模块总开关等）
├── text-proofread/
│   ├── manifest.json
│   ├── proofread.js
│   └── config.json         ← 模块自己的配置
└── smart-text/
    ├── manifest.json
    ├── smart-text.js
    └── config.json         ← 模块自己的配置
```
- 每个模块目录下有自己的 `config.json` 和 `storage.json`
- 全局配置单独目录或在根目录
- 删除模块 = 删目录，配置自动清理
- 导出 .mrm 可选择是否连带配置

### 设计原则
- 全局配置（所有模块共用的、模块系统本身的）→ 根目录/全局目录
- 模块自身设置 → 模块自己目录下
- 对外 API 尽量不变，内部实现逐步演进

---

## 📋 待办事项（Pending）

从之前对话继承的待办：
- P1: 校对模块增加处理日志，输出修改数量和类型
- P2: 音色库多选删除功能
- P2: 音色库间隔选中区间功能
- P2: 音色拉取按钮
- P2: 试听开关
- 生成有错的测试文本用于校对模块测试
