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
| 2 | 缺少 import / 导错 import | `Unresolved reference: Spacer` / `width` 等；或 `Cannot access 'val RowColumnParentData?.weight': it is internal` | 新增 Compose 组件/modifier 时，检查 import 区；注意 `weight` 等作用域扩展不能单独 import | 顶层扩展加 import；作用域扩展不加 |
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

### 5. JS 模块 / Rhino 引擎类

| # | 错误类型 | 症状 | 检查方法 | 修复方式 |
|---|---------|------|----------|----------|
| 1 | 后行断言 `(?<=...)` / `(?<!...)` | `SyntaxError: Invalid quantifier ?` | 模块 JS 里用了 lookbehind 正则 | Rhino 不支持后行断言，改用占位符替换法 |
| 2 | ES6+ 语法（箭头函数、let/const 等） | `SyntaxError` | 模块 JS 里用了 ES6 新语法 | Rhino ES6 模式支持有限，尽量用 ES5 写法 |

---

## 🗂️ 历史错误记录

### 2026-09-05 — ProactiveAnnotationService 语法错误

- **错误**：把 `val defaultSystemPrompt = """..."""` 和 `val systemPrompt = HookPoints.callNullable(...)` 直接写在了 `resolved.client.chat(messages = listOf(...))` 的参数列表内部，导致语法全崩
- **症状**：大量 `Syntax error: Expecting an argument` / `Expecting ')'` / `Unresolved reference`
- **原因**：加钩子时没注意代码结构，把变量声明嵌进了函数调用的参数里
- **修复**：把变量声明移到 `chat()` 调用外面，先声明变量，再在 `chat()` 里引用
- **相关文件**：`app/src/main/java/com/mozhi/reader/ai/companion/ProactiveAnnotationService.kt`

### 2026-09-05 — ModuleSettingsScreen 缺少 import（多次）

- **错误 1**：`Spacer` 和 `Surface` 未导入
  - **症状**：`Unresolved reference 'Spacer'` / `Unresolved reference 'Surface'`
  - **修复**：补上 `import androidx.compose.foundation.layout.Spacer` 和 `import androidx.compose.material3.Surface`

- **错误 2**：`Modifier.width` 和 `Modifier.weight` 未导入 / 导错了
  - **症状 1**：`Unresolved reference 'width'` — 缺少 `width` import
  - **症状 2**：`Cannot access 'val RowColumnParentData?.weight: Float': it is internal in file.` — 给 `weight` 加了 import 反而引到内部属性上了
  - **原因**：Compose 的 modifier 分两种：
    - **顶层扩展**（`width`/`height`/`padding`/`size` 等）— 需要单独 import
    - **作用域扩展**（`weight` 等）— 是 `RowScope`/`ColumnScope` 的成员，在 `Row{}` / `Column{}` lambda 里自动可用，**不能单独 import**
  - **修复**：`width` 加 import，`weight` 不加 import
  - **经验**：看到 `RowScope` / `ColumnScope` 相关的 modifier，先确认是不是作用域内的，别乱加 import

- **经验**：新增 Compose UI 代码时，除了组件（`Spacer`/`Surface` 等），**modifier 扩展（`width`/`weight`/`height` 等）也要检查有没有 import**
- **相关文件**：`app/src/main/java/com/mozhi/reader/feature/settings/ModuleSettingsScreen.kt`

### 2026-09-04 — ModuleSettingsViewModel 废弃类引用

- **错误**：引用了不存在的 `ManifestSetting` 类的 `key` 和 `currentValue` 属性
- **症状**：`Unresolved reference 'key'` / `Unresolved reference 'currentValue'`
- **原因**：配置项数据结构变了，但 ViewModel 里还在用旧结构
- **修复**：移除本地状态更新逻辑，UI 直接从 config 读取
- **相关文件**：`app/src/main/java/com/mozhi/reader/feature/settings/ModuleSettingsViewModel.kt`

### 2026-09-05 — 精校模块 Rhino 正则后行断言不兼容

- **错误**：精校模块 JS 里用了后行断言 `(?<!\u2026)`，Rhino 引擎不支持
- **症状**：`SyntaxError: Invalid quantifier ?`，模块加载失败，完全不工作
- **原因**：Rhino（Mozilla 的 JS 引擎）对 ES2018+ 的正则特性支持有限，后行断言（lookbehind）直接报语法错
- **修复**：用"占位符替换法"代替后行断言 — 先把不需要匹配的内容替换成占位符，做完替换后再还原
- **经验**：写模块 JS 时，正则里别用 `(?<=...)` / `(?<!...)`，前行断言 `(?=...)` / `(?!...)` 是 OK 的
- **相关文件**：`modules/text-proofread.js`

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
