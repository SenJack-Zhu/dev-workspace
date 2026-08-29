# Tool Calling 评估与实现方案

**日期:** 2026-07-26
**状态:** 评估完成,待决策是否实现

## 背景

SillyTavern 自 1.12+ 支持 Chat Completion 工具调用(function calling),1.17/1.18 持续增强:

- 可配置的递归上限(工具调用链最大深度)
- Interleaved thinking(工具调用链中穿插思维链,Claude)
- OpenRouter 工具调用链中的 interleaved reasoning 转发
- 扩展可在工具调用链中处理流式文本

NativeTavern 目前**完全没有** tool calling 支持(代码中无 `tool_call` / `function_call` 相关实现)。

## ST 中工具调用的实际用途

关键洞察:ST 的工具调用**主要由扩展消费**,内置用途有限:

| 消费方 | 用途 |
|---|---|
| Image Generation 扩展 | 模型主动触发图像生成 |
| Web Search 扩展 | 模型主动搜索 |
| Vector Storage | RAG 检索 |
| 第三方扩展 | 自定义工具注册(`registerFunctionTool`) |

NativeTavern 没有 JS 扩展系统(见 `Extension-Compatibility-Analysis.md`),因此
实现工具调用的价值取决于**内置工具**的数量。

## 建议的实现范围(若实施)

### Phase 1: 协议层(约 3-5 天)
- `llm_service.dart`:请求体加入 `tools` / `tool_choice`;解析
  `tool_calls`(OpenAI 格式)、`tool_use` blocks(Claude)、
  `functionCall` parts(Gemini)
- 流式:累积工具调用增量(OpenAI 的 delta.tool_calls 拼接)
- 工具执行循环:`while (response.hasToolCalls && depth < maxRecursion)`,
  默认递归上限 5(对齐 ST)

### Phase 2: 内置工具(约 3-5 天)
按现有服务映射,不需要扩展系统:
- `generate_image` → `image_generation_service.dart`
- `roll_dice` / `random` → 宏系统已有逻辑
- `get_variable` / `set_variable` → `variables_service.dart`
- `search_lorebook` → world info matcher

### Phase 3: UI(约 2-3 天)
- 消息气泡中显示工具调用卡片(名称+参数+结果,可折叠,复用 reasoning 折叠 UI)
- 设置页:启用开关 + 递归上限 + 每个内置工具的开关

## 风险与成本

- 三家 provider 的流式工具调用解析差异大,测试成本高
- 移动端诉求存疑:核心 RP 场景(角色扮演对话)很少需要工具
- 维护面扩大:每新增 provider 都要适配

## 建议

**暂缓**。优先级低于:提示词管理器对齐、向量存储/RAG 完善(Phase 9 规划)。
若用户反馈明确需要"AI 主动生成图片"场景,先做 Phase 1 + 仅
`generate_image` 一个工具的最小闭环。
