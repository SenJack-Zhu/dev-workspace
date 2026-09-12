// ============================================================
// TTS 增强模块 (TTS Enhance Module) v1.2.0
//
// 注册三个 hook:
//   - tts.synthesize:    自定义 TTS 语音合成端点（OpenAI 兼容 / 万能转发器）
//   - tts.voices:         自定义音色列表（静态 JSON / 动态拉取）
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

/**
 * 模板字符串替换，支持 {{变量名}} 占位符
 * @param {string} template - 模板字符串
 * @param {object} vars - 变量键值对
 * @returns {string} 替换后的字符串
 */
function renderTemplate(template, vars) {
    if (!template) return "";
    var result = template;
    for (var key in vars) {
        if (vars.hasOwnProperty(key)) {
            var val = (vars[key] !== undefined && vars[key] !== null) ? String(vars[key]) : "";
            // 使用全局替换
            var placeholder = "{{" + key + "}}";
            while (result.indexOf(placeholder) >= 0) {
                result = result.replace(placeholder, val);
            }
        }
    }
    return result;
}

/**
 * 推断音频 MIME 类型。
 * 优先用服务端声明的 Content-Type；缺失或不规范时按 base64 魔数判断，
 * 最后才回落到请求时指定的格式。
 * @param {string} contentType - 服务端 Content-Type（可能为 null）
 * @param {string} b64 - base64 音频
 * @param {string} requestedFormat - 请求时指定的格式（如 "mp3"）
 * @returns {string} MIME 类型
 */
function guessAudioMediaType(contentType, b64, requestedFormat) {
    if (contentType) {
        var ct = String(contentType).toLowerCase().split(";")[0].trim();
        if (ct.indexOf("audio/") === 0 || ct.indexOf("video/") === 0) return ct;
        if (ct === "application/ogg") return "audio/ogg";
    }
    // 优先用宿主提供的魔数识别（避免在 JS 里重复实现）
    if (typeof MoRead.guessAudioType === "function") {
        var guessed = MoRead.guessAudioType(b64);
        if (guessed && guessed !== "audio/mpeg") return guessed;
    }
    // RIFF/WAVE
    if (b64 && b64.indexOf("UklGR") === 0) return "audio/wav";
    if (b64 && b64.indexOf("T2dnUw") === 0) return "audio/ogg";
    if (b64 && b64.indexOf("ZkxhQ") === 0) return "audio/flac";
    if (requestedFormat) {
        var f = String(requestedFormat).toLowerCase().replace("audio/", "");
        if (f === "wav") return "audio/wav";
        if (f === "ogg") return "audio/ogg";
        if (f === "flac") return "audio/flac";
        if (f === "aac") return "audio/aac";
    }
    return "audio/mpeg";
}

/**
 * 从响应体里提取音频数据，支持多种格式
 * @param {string} body - 响应体
 * @param {string} extractPath - 提取路径，如 "audio" / "data.audio" / ""(整个 body 是 base64)
 * @param {string} defaultFormat - 默认音频格式
 * @returns {object|null} {audio, mediaType} 或 null
 */
function extractAudio(body, extractPath, defaultFormat) {
    if (!body || body.length === 0) return null;

    // 先试试 JSON 解析
    try {
        var json = JSON.parse(body);
        var audioVal = null;
        var mediaTypeVal = null;

        if (extractPath && extractPath.length > 0) {
            // 按路径提取，支持 a.b.c
            var parts = extractPath.split(".");
            var current = json;
            for (var i = 0; i < parts.length; i++) {
                if (current === null || current === undefined) break;
                current = current[parts[i]];
            }
            audioVal = current;
        } else {
            // 自动找常见字段
            audioVal = json.audio || json.data || json.audioData || json.base64;
        }

        if (audioVal && typeof audioVal === "string" && audioVal.length > 50) {
            // 找 mediaType
            mediaTypeVal = json.mediaType || json.format || json.contentType;
            if (!mediaTypeVal && defaultFormat) {
                mediaTypeVal = "audio/" + defaultFormat;
            }
            return {
                audio: audioVal,
                mediaType: mediaTypeVal || "audio/mpeg"
            };
        }
    } catch (e) {
        // 不是 JSON，继续往下
    }

    // 如果整个 body 看起来像 base64
    var b64test = body.replace(/\s/g, "");
    if (/^[A-Za-z0-9+/=]+$/.test(b64test) && b64test.length > 100) {
        return {
            audio: b64test,
            mediaType: defaultFormat ? "audio/" + defaultFormat : "audio/mpeg"
        };
    }

    return null;
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

    // 模式：openai（兼容模式） / universal（万能转发器）
    var mode = getConfig("ttsMode", "openai");

    MoRead.log("[CustomTTS] 端点: " + endpoint);
    MoRead.log("[CustomTTS] 模式: " + mode);

    // ============== 万能转发器模式 ==============
    if (mode === "universal") {
        var method = (getConfig("universalMethod", "GET") || "GET").toUpperCase();
        var urlTemplate = getConfig("universalUrlTemplate", "");
        var headersJson = getConfig("universalHeaders", "{}");
        var bodyTemplate = getConfig("universalBodyTemplate", "");
        var responseExtract = getConfig("universalResponseExtract", "");
        var apiKey = getConfig("ttsApiKey", "");

        // URL 模板为空的话，用 endpoint 作为基础地址拼一下
        if (!urlTemplate) {
            if (method === "GET") {
                var base = endpoint.replace(/\/+$/, "");
                // endpoint 若已带路径（如 http://host:8774/forward）则直接追加查询串；
                // 否则默认按 OpenAI 兼容的 /audio/speech 约定拼接。
                var join = base.indexOf("?", 8) >= 0 ? "&" : "?";
                var looksLikeFullPath = /\/[a-zA-Z]/.test(base.substring(base.indexOf("://") + 3));
                if (looksLikeFullPath) {
                    urlTemplate = base + join + "text={{text}}&voice={{voice}}";
                } else {
                    urlTemplate = base + "/forward?text={{text}}&voice={{voice}}";
                }
            } else {
                urlTemplate = endpoint;
            }
        }

        MoRead.log("[CustomTTS] 方法: " + method);
        MoRead.log("[CustomTTS] URL 模板: " + urlTemplate);

        MoRead.hook("tts.synthesize", function(p) {
            var text = p.text || "";
            if (!text) return null;

            // 收集所有变量
            var speedVal = p.speed || 1.0;
            var volumeVal = p.volume || 1.0;
            var pitchVal = p.pitch || 1.0;
            var vars = {
                text: encodeURIComponent(text),
                rawText: text,
                voice: encodeURIComponent(p.voice || ""),
                rawVoice: p.voice || "",
                speed: speedVal,
                speed100: Math.round(speedVal * 100),
                speedInt: Math.round(speedVal),
                volume: volumeVal,
                volume100: Math.round(volumeVal * 100),
                volumeInt: Math.round(volumeVal),
                pitch: pitchVal,
                pitch100: Math.round(pitchVal * 100),
                pitchInt: Math.round(pitchVal),
                model: encodeURIComponent(p.model || ""),
                rawModel: p.model || "",
                format: p.responseFormat || "mp3"
            };

            // 渲染 URL
            var url = renderTemplate(urlTemplate, vars);

            // ── 请求行长度守卫 ──
            // 多数自建 TTS 服务只接受 URL 查询串传参，且请求行硬上限约 8 KB。
            // 中文经 encodeURIComponent 后每字 9 字节，超限时服务端会直接断开连接
            // 且不给任何响应，表现为「朗读莫名停止」。这里提前拦截并给出可操作提示。
            var SAFE_URL_BYTES = getConfigInt("maxUrlBytes", 7000);
            var urlBytes = url.length;
            if (urlBytes > SAFE_URL_BYTES) {
                MoRead.log("[CustomTTS] URL 超长，已放弃本次合成: " + urlBytes +
                    " 字节 (上限 " + SAFE_URL_BYTES + ")，文本 " + text.length + " 字");
                MoRead.log("[CustomTTS] 建议：把「单句最大字符数」调小到 400 以下，或改用非 GET 传参的服务");
                return null;
            }

            // 渲染请求头
            var headers = {};
            try {
                if (headersJson && headersJson.trim()) {
                    var parsedHeaders = JSON.parse(headersJson);
                    for (var hk in parsedHeaders) {
                        if (parsedHeaders.hasOwnProperty(hk)) {
                            headers[hk] = renderTemplate(parsedHeaders[hk], vars);
                        }
                    }
                }
            } catch (e) {
                MoRead.log("[CustomTTS] ⚠️ 请求头 JSON 解析失败: " + e.message);
            }
            if (apiKey && !headers["Authorization"]) {
                headers["Authorization"] = "Bearer " + apiKey;
            }
            if (method === "POST" && !headers["Content-Type"]) {
                headers["Content-Type"] = "application/json";
            }

            var preview = text.length > 60 ? text.substring(0, 60) + "..." : text;
            MoRead.log("[CustomTTS] 合成: \"" + preview + "\" voice=" + (p.voice || "(自动)"));

            try {
                var resp;

                if (method === "GET") {
                    resp = MoRead.httpGet(url, headers);
                } else {
                    var body = bodyTemplate ? renderTemplate(bodyTemplate, vars) : "";
                    resp = MoRead.httpPost(url, body, headers["Content-Type"] || "application/json", headers);
                }

                if (!resp || !resp.ok) {
                    var status = resp ? resp.status : "no response";
                    MoRead.log("[CustomTTS] 请求失败: HTTP " + status);
                    if (resp && resp.body) {
                        MoRead.log("[CustomTTS] 响应: " + resp.body.substring(0, 200));
                    }
                    return null;
                }

                // ── 二进制优先 ──
                // 音频必须以 base64 原样取回；任何经过文本解码的路径都会毁掉字节。
                if (resp.base64 && resp.base64.length > 0) {
                    var mt = guessAudioMediaType(resp.contentType, resp.base64, p.responseFormat);
                    MoRead.log("[CustomTTS] 合成成功（二进制）" +
                        MoRead.bytesLength(resp.base64) + " 字节, " + mt);
                    return JSON.stringify({ audio: resp.base64, mediaType: mt });
                }

                // 文本响应：可能是 JSON 里包着 base64
                var result = extractAudio(resp.body, responseExtract, p.responseFormat || "mp3");
                if (result) {
                    MoRead.log("[CustomTTS] 合成成功, 音频长度: " + result.audio.length);
                    return JSON.stringify(result);
                }

                MoRead.log("[CustomTTS] 无法从响应中提取音频数据");
                if (resp.body && resp.body.length < 500) {
                    MoRead.log("[CustomTTS] 响应内容: " + resp.body);
                }
                return null;

            } catch (e) {
                MoRead.log("[CustomTTS] 异常: " + e.message);
                return null;
            }
        });

        MoRead.log("[CustomTTS] 已注册 hook: tts.synthesize (万能转发器模式) ✓");
        return;
    }

    // ============== OpenAI 兼容模式（默认） ==============
    MoRead.hook("tts.synthesize", function(p) {
        var text = p.text || "";
        if (!text) return null;

        var voice = getConfig("ttsDefaultVoice", "");
        var model = getConfig("ttsModel", "");
        var format = getConfig("ttsFormat", "");
        var apiKey = getConfig("ttsApiKey", "");
        var speed = p.speed || 1.0;

        if (p.voice) voice = p.voice;
        if (p.model) model = p.model;
        if (p.responseFormat) format = p.responseFormat;

        var preview = text.length > 60 ? text.substring(0, 60) + "..." : text;
        MoRead.log("[CustomTTS] 合成: \"" + preview + "\" voice=" + (voice || "(自动)") + " model=" + (model || "(自动)"));

        var bodyObj = { input: text };
        if (model) bodyObj.model = model;
        if (voice) bodyObj.voice = voice;
        if (format) bodyObj.response_format = format;
        if (speed && speed !== 1.0) bodyObj.speed = speed;
        var body = JSON.stringify(bodyObj);

        var headers = { "Content-Type": "application/json" };
        if (apiKey) headers["Authorization"] = "Bearer " + apiKey;

        var baseUrl = endpoint.replace(/\/+$/, "");
        var url = baseUrl + "/v1/audio/speech";

        try {
            var resp = MoRead.httpPost(url, body, "application/json", headers);

            if (!resp || !resp.ok) {
                var status = resp ? resp.status : "no response";
                MoRead.log("[CustomTTS] 请求失败: HTTP " + status);
                if (resp && resp.body) {
                    MoRead.log("[CustomTTS] 响应: " + resp.body.substring(0, 200));
                }
                return null;
            }

            var result = extractAudio(resp.body, "", format);
            if (result) {
                MoRead.log("[CustomTTS] 合成成功 (OpenAI 模式)");
                return JSON.stringify(result);
            }

            MoRead.log("[CustomTTS] 无法解析响应格式");
            return null;

        } catch (e) {
            MoRead.log("[CustomTTS] 异常: " + e.message);
            return null;
        }
    });

    MoRead.log("[CustomTTS] 已注册 hook: tts.synthesize (OpenAI 模式) ✓");
}

// ------------------------------------------------------------
// 2. 自定义音色列表 (tts.voices)
// ------------------------------------------------------------
function initCustomVoices() {
    if (!isEnabled("enableCustomVoices")) return;

    var source = getConfig("voicesSource", "static"); // static / dynamic

    // ============== 动态拉取模式 ==============
    if (source === "dynamic") {
        var voicesUrl = getConfig("dynamicVoicesUrl", "");
        var voicesExtract = getConfig("dynamicVoicesExtract", ""); // 提取路径
        var voiceIdField = getConfig("dynamicVoiceIdField", "voiceId");
        var voiceNameField = getConfig("dynamicVoiceNameField", "displayName");
        var voicesHeadersJson = getConfig("dynamicVoicesHeaders", "{}");

        if (!voicesUrl) {
            MoRead.log("[CustomVoices] 动态模式但未配置 URL，跳过");
            return;
        }

        MoRead.log("[CustomVoices] 动态拉取: " + voicesUrl);

        // 拉取音色列表
        var voices = null;
        try {
            var headers = {};
            if (voicesHeadersJson && voicesHeadersJson.trim()) {
                headers = JSON.parse(voicesHeadersJson);
            }
            var apiKey = getConfig("ttsApiKey", "");
            if (apiKey) headers["Authorization"] = "Bearer " + apiKey;

            var resp = MoRead.httpGet(voicesUrl, headers);
            if (!resp || !resp.ok) {
                MoRead.log("[CustomVoices] 拉取失败: HTTP " + (resp ? resp.status : "no response"));
                return;
            }

            var json = JSON.parse(resp.body);

            // 按路径提取
            var extracted = json;
            if (voicesExtract && voicesExtract.length > 0) {
                var parts = voicesExtract.split(".");
                for (var i = 0; i < parts.length; i++) {
                    if (extracted === null || extracted === undefined) break;
                    extracted = extracted[parts[i]];
                }
            }

            // 支持两种格式：
            // 1. 直接是数组 → 用它
            // 2. 是对象（字典）→ 把所有 value 是数组的合并（适用于 catalog 分类结构）
            var arr = null;
            if (extracted && Array.isArray(extracted)) {
                arr = extracted;
            } else if (extracted && typeof extracted === "object") {
                arr = [];
                for (var k in extracted) {
                    if (extracted.hasOwnProperty(k) && Array.isArray(extracted[k])) {
                        // 给每个音色加上分类标签
                        for (var ki = 0; ki < extracted[k].length; ki++) {
                            var item = extracted[k][ki];
                            if (item && typeof item === "object") {
                                item._catalog = k; // 临时字段，后面转 tag
                            }
                        }
                        arr = arr.concat(extracted[k]);
                    }
                }
            }

            if (!arr || !arr.length) {
                MoRead.log("[CustomVoices] 音色列表为空");
                return;
            }

            // 转换成标准格式
            voices = [];
            for (var j = 0; j < arr.length; j++) {
                var item = arr[j];
                var vid = item[voiceIdField] || item.id || item.voice_id || item.voiceId || "";
                var vname = item[voiceNameField] || item.name || item.display_name || item.displayName || vid;
                if (vid) {
                    // 组装 tags：gender + locale + type + catalog + desc
                    var tagList = [];
                    if (item.gender) tagList.push(item.gender);
                    if (item.locale) tagList.push(item.locale);
                    if (item.type) tagList.push(item.type);
                    if (item._catalog) tagList.push(item._catalog);
                    if (item.desc) tagList.push(item.desc);
                    voices.push({
                        voiceId: vid,
                        displayName: vname,
                        gender: (item.gender || "").toUpperCase() === "FEMALE" ? "FEMALE"
                              : (item.gender || "").toUpperCase() === "MALE" ? "MALE"
                              : "UNSPECIFIED",
                        tags: tagList.join(",")
                    });
                }
            }

            MoRead.log("[CustomVoices] 动态加载 " + voices.length + " 个音色");

        } catch (e) {
            MoRead.log("[CustomVoices] 动态拉取异常: " + e.message);
            return;
        }

        if (voices && voices.length > 0) {
            MoRead.hook("tts.voices", function(p) {
                MoRead.log("[CustomVoices] 返回 " + voices.length + " 个音色（动态）");
                return JSON.stringify(voices);
            });
            MoRead.log("[CustomVoices] 已注册 hook: tts.voices (动态模式) ✓");
        }
        return;
    }

    // ============== 静态配置模式（默认） ==============
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

    MoRead.log("[CustomVoices] 已注册 hook: tts.voices (静态模式) ✓");
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

        while (lineStart <= len) {
            var newline = body.indexOf('\n', lineStart);
            var lineEnd = newline < 0 ? len : newline;

            var start = lineStart;
            var i = lineStart;

            while (i < lineEnd) {
                if (isTerminator(body[i])) {
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

            if (start < lineEnd) {
                addClamped(body, start, lineEnd, max, spans);
            }

            if (newline < 0) break;
            lineStart = newline + 1;
        }

        MoRead.log("[CustomSegmenter] 切出 " + spans.length + " 句");
        return JSON.stringify(spans);
    });

    function addClamped(body, rawStart, rawEnd, maxChars, out) {
        var trimmed = trimRange(body, rawStart, rawEnd);
        var start = trimmed.start;
        var end = trimmed.end;
        if (start >= end) return;

        var cursor = start;
        while (end - cursor > maxChars) {
            var windowEnd = cursor + maxChars;
            var cut = -1;
            var k = windowEnd;
            var floor = cursor + Math.floor(maxChars / 3);
            while (k > floor) {
                if (isSoftBreak(body[k - 1])) {
                    cut = k;
                    break;
                }
                k--;
            }
            if (cut < 0) cut = windowEnd;
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

MoRead.log("TTS 增强模块 v1.2.0 加载完成");
if (activeHooks.length > 0) {
    MoRead.log("已激活 hook: " + activeHooks.join(", "));
} else {
    MoRead.log("所有功能均未启用，请在设置中开启需要的功能");
}
