// ============================================================
// TTS 增强模块 (TTS Enhance Module) v1.0.0
//
// 注册三个 hook:
//   - tts.synthesize:    自定义 TTS 语音合成端点
//   - tts.voices:         自定义音色列表
//   - listen.sentence:    自定义句子断句规则
//
// 所有功能均可独立开关，通过设置面板配置。
// ============================================================

var MODULE_NAME = "tts-enhance";

// ------------------------------------------------------------
// 工具函数
// ------------------------------------------------------------
function isEnabled(key) {
    return MoRead.configGet(key, "false") === "true";
}

function getConfig(key, def) {
    return MoRead.configGet(key, def);
}

function getConfigInt(key, def) {
    var v = parseInt(MoRead.configGet(key, String(def)), 10);
    return isNaN(v) ? def : v;
}

// ------------------------------------------------------------
// 1. 自定义 TTS 端点 (tts.synthesize)
// ------------------------------------------------------------
function initCustomTTS() {
    if (!isEnabled("enableCustomTTS")) return;

    var endpoint = getConfig("ttsEndpoint", "");
    if (!endpoint) {
        MoRead.log("[CustomTTS] 未配置 TTS 端点，跳过");
        return;
    }

    MoRead.log("[CustomTTS] 端点: " + endpoint);

    MoRead.hook("tts.synthesize", function(p) {
        var text = p.text || "";
        if (!text) return null;

        var voice = (p.voice || getConfig("ttsDefaultVoice", "alloy")).trim();
        var model = p.model || getConfig("ttsModel", "cosyvoice-v1");
        var format = p.responseFormat || getConfig("ttsFormat", "mp3");
        var apiKey = getConfig("ttsApiKey", "");
        var speed = p.speed || 1.0;

        var preview = text.length > 60 ? text.substring(0, 60) + "..." : text;
        MoRead.log("[CustomTTS] 合成: \"" + preview + "\" voice=" + voice + " model=" + model);

        // 构建请求体（OpenAI 兼容格式）
        var bodyObj = {
            model: model,
            input: text,
            voice: voice,
            response_format: format
        };
        if (speed && speed !== 1.0) {
            bodyObj.speed = speed;
        }
        var body = JSON.stringify(bodyObj);

        // 构建请求头
        var headers = {
            "Content-Type": "application/json"
        };
        if (apiKey) {
            headers["Authorization"] = "Bearer " + apiKey;
        }

        // 确保端点不以 / 结尾
        var baseUrl = endpoint.replace(/\/+$/, "");
        var url = baseUrl + "/v1/audio/speech";

        try {
            var resp = MoRead.httpPost(url, body, "application/json", headers);

            if (!resp || !resp.ok) {
                var status = resp ? resp.status : "no response";
                MoRead.log("[CustomTTS] 请求失败: HTTP " + status);
                if (resp && resp.body) {
                    var errPreview = resp.body.substring(0, 200);
                    MoRead.log("[CustomTTS] 响应: " + errPreview);
                }
                return null; // 回退到内置 TTS
            }

            // 尝试解析 JSON 响应 { audio: base64, mediaType: "..." }
            try {
                var json = JSON.parse(resp.body);
                if (json.audio || json.data) {
                    MoRead.log("[CustomTTS] 合成成功 (JSON 格式)");
                    return JSON.stringify({
                        audio: json.audio || json.data,
                        mediaType: json.mediaType || json.format || ("audio/" + format)
                    });
                }
            } catch (e) {
                // 不是 JSON，可能是直接返回二进制的 base64
            }

            // 如果响应体看起来像 base64，直接使用
            if (resp.body && resp.body.length > 0) {
                // 简单检测：检查是否为 base64 字符
                var b64test = resp.body.replace(/\s/g, "");
                if (/^[A-Za-z0-9+/=]+$/.test(b64test) && b64test.length > 100) {
                    MoRead.log("[CustomTTS] 合成成功 (base64 格式, 长度=" + b64test.length + ")");
                    return JSON.stringify({
                        audio: b64test,
                        mediaType: "audio/" + format
                    });
                }
                // 如果响应体较短，可能是错误信息
                if (resp.body.length < 500) {
                    MoRead.log("[CustomTTS] 响应内容异常: " + resp.body.substring(0, 200));
                    return null;
                }
            }

            MoRead.log("[CustomTTS] 无法解析响应格式");
            return null;

        } catch (e) {
            MoRead.log("[CustomTTS] 异常: " + e.message);
            return null;
        }
    });

    MoRead.log("[CustomTTS] 已注册 hook: tts.synthesize ✓");
}

// ------------------------------------------------------------
// 2. 自定义音色列表 (tts.voices)
// ------------------------------------------------------------
function initCustomVoices() {
    if (!isEnabled("enableCustomVoices")) return;

    var voicesJson = getConfig("customVoices", "");
    if (!voicesJson) {
        MoRead.log("[CustomVoices] 未配置音色列表，跳过");
        return;
    }

    var voices;
    try {
        voices = JSON.parse(voicesJson);
    } catch (e) {
        MoRead.log("[CustomVoices] 音色列表 JSON 解析失败: " + e.message);
        return;
    }

    if (!voices || !voices.length) {
        MoRead.log("[CustomVoices] 音色列表为空，跳过");
        return;
    }

    MoRead.log("[CustomVoices] 已加载 " + voices.length + " 个自定义音色");

    MoRead.hook("tts.voices", function(p) {
        MoRead.log("[CustomVoices] 返回 " + voices.length + " 个音色");
        return JSON.stringify(voices);
    });

    MoRead.log("[CustomVoices] 已注册 hook: tts.voices ✓");
}

// ------------------------------------------------------------
// 3. 自定义句子断句 (listen.sentence)
// ------------------------------------------------------------
function initCustomSegmenter() {
    if (!isEnabled("enableCustomSegmenter")) return;

    var maxChars = getConfigInt("segmentMaxChars", 96);
    var terminators = getConfig("segmentTerminators", "。！？!?…；;");
    var softBreaks = getConfig("segmentSoftBreaks", "，,、：: 　");

    MoRead.log("[CustomSegmenter] 最大字符数: " + maxChars);
    MoRead.log("[CustomSegmenter] 终止标点: " + terminators);
    MoRead.log("[CustomSegmenter] 次级停顿: " + softBreaks);

    // 收引号/括号字符，断句时归前句
    var closers = "」』”'\"'）)】]〕〉》";

    function isTerminator(ch) {
        return terminators.indexOf(ch) >= 0;
    }

    function isCloser(ch) {
        return closers.indexOf(ch) >= 0;
    }

    function isSoftBreak(ch) {
        return softBreaks.indexOf(ch) >= 0;
    }

    function isIgnorable(ch) {
        return ch === ' ' || ch === '\t' || ch === '\u3000' || ch === '\uFFFC';
    }

    function trimRange(body, start, end) {
        var s = start;
        var e = end;
        while (s < e && isIgnorable(body[s])) s++;
        while (e > s && isIgnorable(body[e - 1])) e--;
        return { start: s, end: e };
    }

    MoRead.hook("listen.sentence", function(p) {
        var body = p.body || "";
        var max = p.maxChars || maxChars;

        if (!body) return JSON.stringify([]);

        var spans = [];
        var lineStart = 0;
        var len = body.length;

        // 按行处理
        while (lineStart <= len) {
            var newline = body.indexOf('\n', lineStart);
            var lineEnd = newline < 0 ? len : newline;

            // 处理一行内的断句
            var start = lineStart;
            var i = lineStart;

            while (i < lineEnd) {
                if (isTerminator(body[i])) {
                    // 找到终止标点，往后吃掉收引号
                    var end = i + 1;
                    while (end < lineEnd && (isTerminator(body[end]) || isCloser(body[end]))) {
                        end++;
                    }
                    addClamped(body, start, end, max, spans);
                    start = end;
                    i = end;
                } else {
                    i++;
                }
            }

            // 行尾剩余部分
            if (start < lineEnd) {
                addClamped(body, start, lineEnd, max, spans);
            }

            if (newline < 0) break;
            lineStart = newline + 1;
        }

        MoRead.log("[CustomSegmenter] 切出 " + spans.length + " 句");
        return JSON.stringify(spans);
    });

    // 辅助：超长句在次级停顿处折分
    function addClamped(body, rawStart, rawEnd, maxChars, out) {
        var trimmed = trimRange(body, rawStart, rawEnd);
        var start = trimmed.start;
        var end = trimmed.end;
        if (start >= end) return;

        var cursor = start;
        while (end - cursor > maxChars) {
            var windowEnd = cursor + maxChars;
            var cut = -1;
            // 从窗口尾部向前找次级停顿；切点不早于窗口 1/3 处
            var k = windowEnd;
            var floor = cursor + Math.floor(maxChars / 3);
            while (k > floor) {
                if (isSoftBreak(body[k - 1])) {
                    cut = k;
                    break;
                }
                k--;
            }
            if (cut < 0) cut = windowEnd; // 实在找不到就硬切
            var t = trimRange(body, cursor, cut);
            if (t.start < t.end) out.push({ start: t.start, end: t.end });
            cursor = cut;
        }
        var t2 = trimRange(body, cursor, end);
        if (t2.start < t2.end) out.push({ start: t2.start, end: t2.end });
    }

    MoRead.log("[CustomSegmenter] 已注册 hook: listen.sentence ✓");
}

// ------------------------------------------------------------
// 初始化
// ------------------------------------------------------------
MoRead.log("TTS 增强模块初始化...");

initCustomTTS();
initCustomVoices();
initCustomSegmenter();

var activeHooks = [];
if (isEnabled("enableCustomTTS")) activeHooks.push("tts.synthesize");
if (isEnabled("enableCustomVoices")) activeHooks.push("tts.voices");
if (isEnabled("enableCustomSegmenter")) activeHooks.push("listen.sentence");

MoRead.log("TTS 增强模块 v1.0.0 加载完成");
if (activeHooks.length > 0) {
    MoRead.log("已激活 hook: " + activeHooks.join(", "));
} else {
    MoRead.log("所有功能均未启用，请在设置中开启需要的功能");
}
