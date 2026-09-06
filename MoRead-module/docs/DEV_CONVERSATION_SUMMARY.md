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

## 📋 待办事项（Pending）

从之前对话继承的待办：
- P1: 校对模块增加处理日志，输出修改数量和类型
- P2: 音色库多选删除功能
- P2: 音色库间隔选中区间功能
- P2: 音色拉取按钮
- P2: 试听开关
- 生成有错的测试文本用于校对模块测试
