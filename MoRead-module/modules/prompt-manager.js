// ============================================================
// 提示词管理器模块 (Prompt Manager) v0.1.0
//
// 功能：
//   1. 集中管理各个 AI 功能的 System Prompt
//   2. 每个功能可独立开关，关闭时使用默认提示词
//   3. 支持酒馆角色卡 JSON 导入，自动映射到各功能
//
// 注册钩子：
//   - prompt.audiobook.script.system     有声书剧本生成
//   - prompt.annotation.proactive.system  随读段评
// ============================================================

var VERSION = "0.1.0";

// ------------------------------------------------------------
// 配置读取
// ------------------------------------------------------------
function cfg(key, def) {
    return MoRead.configGet(key, def);
}

function cfgBool(key, def) {
    return cfg(key, def ? "true" : "false") === "true";
}

// ------------------------------------------------------------
// 酒馆角色卡解析（轻量版）
// 支持 SillyTavern V1/V2/V3 格式
// ------------------------------------------------------------
function parseTavernCard(jsonStr) {
    if (!jsonStr || jsonStr.trim().length < 10) return null;
    try {
        var card = JSON.parse(jsonStr);
        var data = card.data || card; // V2/V3 在 data 下，V1 在根级

        var name = data.name || "";
        var description = data.description || "";
        var personality = data.personality || "";
        var scenario = data.scenario || "";
        var firstMes = data.first_mes || "";
        var mesExample = data.mes_example || "";

        // 合并人设
        var fullPersonality = "";
        if (description) fullPersonality += description + "\n\n";
        if (personality) fullPersonality += "性格特质：" + personality + "\n\n";
        if (scenario) fullPersonality += "场景设定：" + scenario;

        // 替换宏
        if (name) {
            fullPersonality = fullPersonality.replace(/\{\{char\}\}/gi, name);
            fullPersonality = fullPersonality.replace(/\{\{user\}\}/gi, "用户");
        }

        return {
            name: name,
            personality: fullPersonality.trim(),
            firstMes: firstMes,
            mesExample: mesExample
        };
    } catch (e) {
        MoRead.log("[PromptManager] 角色卡解析失败: " + e.message);
        return null;
    }
}

// ------------------------------------------------------------
// 应用角色卡到各 prompt
// ------------------------------------------------------------
function applyCharacterCard(card) {
    if (!card || !card.name) return 0;
    var count = 0;

    // 保存到配置（作为参考信息展示）
    // 注意：模块不能自己写配置，只能读。这里只记录到 storage 供日志用
    var cardInfo = {
        name: card.name,
        personality: card.personality,
        appliedAt: Date.now()
    };
    MoRead.storageSet("prompt_manager_card", JSON.stringify(cardInfo));
    MoRead.log("[PromptManager] 角色卡已加载: " + card.name);

    // 后续可以在这里自动生成各功能的自定义 prompt
    // 目前 v0.1 只做解析和展示，用户手动复制到各 prompt 设置项

    return count;
}

// ------------------------------------------------------------
// 钩子 1: prompt.audiobook.script.system
// ------------------------------------------------------------
function initAudiobookScriptHook() {
    if (!cfgBool("enableAudiobookScript", false)) return;

    var customPrompt = cfg("audiobookScriptPrompt", "").trim();
    if (!customPrompt) {
        MoRead.log("[PromptManager] 有声书剧本自定义已启用但 prompt 为空，使用默认");
        return;
    }

    MoRead.log("[PromptManager] 注册钩子: prompt.audiobook.script.system");

    MoRead.hook("prompt.audiobook.script.system", function(params) {
        var prompt = cfg("audiobookScriptPrompt", "").trim();
        if (!prompt) return null; // 空的就用默认

        // 支持简单的变量替换
        prompt = prompt.replace(/\{bookId\}/g, params.bookId || "");
        prompt = prompt.replace(/\{chapterTitle\}/g, params.chapterTitle || "");
        prompt = prompt.replace(/\{roleCount\}/g, params.roleCount || "");

        return prompt;
    });
}

// ------------------------------------------------------------
// 钩子 2: prompt.annotation.proactive.system
// ------------------------------------------------------------
function initProactiveAnnotationHook() {
    if (!cfgBool("enableProactiveAnnotation", false)) return;

    var customPrompt = cfg("proactiveAnnotationPrompt", "").trim();
    if (!customPrompt) {
        MoRead.log("[PromptManager] 随读段评自定义已启用但 prompt 为空，使用默认");
        return;
    }

    MoRead.log("[PromptManager] 注册钩子: prompt.annotation.proactive.system");

    MoRead.hook("prompt.annotation.proactive.system", function(params) {
        var prompt = cfg("proactiveAnnotationPrompt", "").trim();
        if (!prompt) return null;

        prompt = prompt.replace(/\{bookId\}/g, params.bookId || "");
        prompt = prompt.replace(/\{chapterIndex\}/g, params.chapterIndex || "");
        prompt = prompt.replace(/\{maxAnnotations\}/g, params.maxAnnotations || "");

        return prompt;
    });
}

// ------------------------------------------------------------
// 初始化
// ------------------------------------------------------------
MoRead.log("提示词管理器初始化...");

// 尝试解析角色卡（如果用户粘贴了）
var tavernCardJson = cfg("tavernCardJson", "");
if (tavernCardJson && tavernCardJson.trim().length > 20) {
    var card = parseTavernCard(tavernCardJson);
    if (card) {
        applyCharacterCard(card);
    }
}

initAudiobookScriptHook();
initProactiveAnnotationHook();

var activeHooks = [];
if (cfgBool("enableAudiobookScript", false) && cfg("audiobookScriptPrompt", "").trim()) {
    activeHooks.push("audiobook.script");
}
if (cfgBool("enableProactiveAnnotation", false) && cfg("proactiveAnnotationPrompt", "").trim()) {
    activeHooks.push("annotation.proactive");
}

MoRead.log("提示词管理器 v" + VERSION + " 加载完成");
MoRead.log("已启用自定义 Prompt: " + (activeHooks.length ? activeHooks.join(", ") : "无（全部使用默认）"));
MoRead.log("提示：关闭对应开关即可恢复默认提示词");
