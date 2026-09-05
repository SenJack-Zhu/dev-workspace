# 编译错误知识库

> 每次推送代码前，从上到下过一遍这个清单，确保不会重复踩坑。

---

## 🚨 工作原则（置顶）

### 原则 1：新错误交给 GitHub Actions 跑

遇到之前没出现过的错误，**不要在本地折腾**，直接推送让 CI 跑。
- 本地环境可能跟 CI 不一致（JDK 版本、Gradle 缓存、网络等）
- CI 是唯一可信的构建环境
- 本地排查浪费时间，还不一定复现

### 原则 2：推送前先确认，不浪费 Actions 额度

不是所有改动都需要立刻推送，**推送前先找用户确认一下**。
- 小改动、中间状态、不确定的改动，先本地提交不推送
- Actions 额度不是无限的，没必要的编译能省则省
- 用户说"可以推了"再推，用户没说就先攒着

### 原则 3：先看错误再删 run，日志是证据

清理失败的 Actions 之前，**先把错误日志看明白、原因搞清楚、修复做完、写进文档**，最后再删。
- 删了 run 就看不到日志了，等于把证据毁了
- 没搞清楚的错误一定会再犯
- 顺序：看日志 → 定位原因 → 修复 → 补充文档 → 确认修复成功 → 再清理失败记录

### 原则 4：推送即收尾，不阻塞等结果

推送完代码，**当前阶段任务就结束了**，不需要盯着等构建结果。
- 构建失败用户会收到邮件通知
- 用户反馈失败后再回来排查
- 把时间花在做事情上，不是等事情上

---

## 📋 推送前检查清单

按顺序检查，每一条都过一遍：

### 1. 语法 / 结构类

| # | 错误类型 | 症状 | 检查方法 | 修复方式 |
|---|---------|------|----------|----------|
| 1 | 变量声明写到函数参数里 | `Syntax error: Expecting an argument` / `Expecting ')'` | 检查新增的 `val` / `var` 是不是在 `fun(...)` 的括号内 | 把变量声明移到函数调用外面 |
| 2 | 缺少 import | `Unresolved reference: Spacer` / `Surface` / 其他 Compose 组件 | 新增用了 Compose 组件时，检查 import 区有没有对应类 | 加上 `import androidx.compose.foundation.layout.Spacer` 等 |
| 3 | Composable 上下文错误 | `@Composable invocations can only happen from the context of a @Composable function` | 检查是不是在非 Composable 函数里调用了 Composable | 确保调用链上都有 `@Composable` 注解 |

### 2. 类型 / 签名类

| # | 错误类型 | 症状 | 检查方法 | 修复方式 |
|---|---------|------|----------|----------|
| 1 | 参数类型不匹配 | `Argument type mismatch: actual type is 'String', but 'XXX' was expected` | 检查函数调用时传的参数类型对不对 | 修正参数类型或调整调用方式 |
| 2 | JVM 签名冲突 | `Platform declaration clash` | 有重载函数在 JVM 层面签名相同时 | 用 `@JvmName` 或改参数名 |
| 3 | Hilt 注入缺失 | `Unresolved reference` / 找不到依赖 | 新增的类如果用了 `@Inject`，检查有没有加到 Hilt 模块里 | 在对应 Module 里加 `@Binds` 或 `@Provides` |

### 3. 钩子埋点类

| # | 错误类型 | 症状 | 检查方法 | 修复方式 |
|---|---------|------|----------|----------|
| 1 | HookPoints / HookRegistry 混淆 | 用了 `HookPoints` 但实际应该用注入的 `hookRegistry` | 检查是在 object 单例里还是在注入类里 | object 用 `HookPoints`，注入类用 `hookRegistry` |
| 2 | 钩子返回值类型不对 | 类型转换异常 | 确认钩子返回的是 `String` / `Boolean` / 其他类型 | 统一返回值类型，模块侧也要对应 |
| 3 | 忘记加默认值 | 调用 `HookPoints.call()` 没传默认值 | 检查每个 `call()` / `callNullable()` 调用 | 必须有 fallback 默认值，模块返回 null 时用默认 |

### 4. 资源 / 配置类

| # | 错误类型 | 症状 | 检查方法 | 修复方式 |
|---|---------|------|----------|----------|
| 1 | 资源文件编码 | 中文乱码 / 资源找不到 | 新增资源文件时检查编码和路径 | 确保 UTF-8 编码，路径正确 |
| 2 | Manifest 冲突 | `Manifest merger failed` | 新增权限 / Activity 时检查 AndroidManifest | 用 `tools:replace` 或合并配置 |

---

## 🗂️ 历史错误记录

### 2026-09-05 — ProactiveAnnotationService 语法错误

- **错误**：把 `val defaultSystemPrompt = """..."""` 和 `val systemPrompt = HookPoints.callNullable(...)` 直接写在了 `resolved.client.chat(messages = listOf(...))` 的参数列表内部，导致语法全崩
- **症状**：大量 `Syntax error: Expecting an argument` / `Expecting ')'` / `Unresolved reference`
- **原因**：加钩子时没注意代码结构，把变量声明嵌进了函数调用的参数里
- **修复**：把变量声明移到 `chat()` 调用外面，先声明变量，再在 `chat()` 里引用
- **相关文件**：`app/src/main/java/com/mozhi/reader/ai/companion/ProactiveAnnotationService.kt`

### 2026-09-05 — ModuleSettingsScreen 缺少 import

- **错误**：`Spacer` 和 `Surface` 未导入
- **症状**：`Unresolved reference 'Spacer'` / `Unresolved reference 'Surface'`
- **原因**：新增 UI 代码时用了 Compose 组件但忘了加 import
- **修复**：补上 `import androidx.compose.foundation.layout.Spacer` 和 `import androidx.compose.material3.Surface`
- **相关文件**：`app/src/main/java/com/mozhi/reader/feature/settings/ModuleSettingsScreen.kt`

### 2026-09-04 — ModuleSettingsViewModel 废弃类引用

- **错误**：引用了不存在的 `ManifestSetting` 类的 `key` 和 `currentValue` 属性
- **症状**：`Unresolved reference 'key'` / `Unresolved reference 'currentValue'`
- **原因**：配置项数据结构变了，但 ViewModel 里还在用旧结构
- **修复**：移除本地状态更新逻辑，UI 直接从 config 读取
- **相关文件**：`app/src/main/java/com/mozhi/reader/feature/settings/ModuleSettingsViewModel.kt`

### 2026-09-04 — Hilt 依赖注入缺失

- **错误**：新增的类需要 `HookRegistry` 但没有注入
- **症状**：编译通过但运行时报错 / 找不到 bean
- **原因**：`LibraryRepository` 和 `ListenEngine` 加了 `HookRegistry` 依赖但没走 Hilt
- **修复**：构造函数加 `@Inject` 注解，确认 Hilt 能提供依赖
- **相关文件**：`LibraryRepository.kt` / `ListenEngine.kt`

---

## ✅ 推送前自查流程

```
1. 过一遍上面的检查清单（语法 → 类型 → 钩子 → 资源）
2. 想想这次改动涉及哪些文件，对照历史错误看有没有相似的坑
3. 确认 import 都加了
4. 确认新增的钩子都有默认值 fallback
5. git diff 过一遍，确认没有误改
6. 本地提交（不推送）
7. 找用户确认："要推送吗？"
8. 用户说推再推送
9. 完事，不等结果，失败了用户会说
```

## 🧹 清理失败 Actions 流程

```
1. 用户说"把失败的 run 删了"
2. 先别急着删！先把每个失败 run 的日志都看一遍
3. 记录错误信息、定位原因
4. 如果是新错误，先修复，再补充到 ERRORS.md
5. 确认修复后的构建成功了
6. 最后再批量删除失败/取消的 run
7. 顺序不能乱：看日志 → 修复 → 写文档 → 确认成功 → 删除
```
