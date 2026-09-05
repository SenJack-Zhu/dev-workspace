// ============================================================
// 智能文本理解模块 (Smart Text Module) v0.1.0
//
// 核心能力：
//   1. 专有名词识别（人名/地名/书名/门派名等）
//   2. 对话 vs 引用/专有名词 区分
//   3. 自增长知识库（AI 学习 + 用户纠正）
//   4. 三种 AI 模式：全书预扫 / 逐章学习 / 纯规则
//
// 注册钩子：
//   - dialogue.segment  智能对白切分
//   - text.preprocess   TTS 文本优化
//
// TODO:
//   - text.display      智能显示标注
//   - listen.sentence   智能断句
// ============================================================

var MODULE_NAME = "smart-text";
var STORAGE_KEY = "smart_text_knowledge_v1";
var STATS_KEY = "smart_text_stats_v1";

// ------------------------------------------------------------
// 配置读取
// ------------------------------------------------------------
function cfg(key, def) {
    return MoRead.configGet(key, def);
}

function cfgBool(key, def) {
    return cfg(key, def ? "true" : "false") === "true";
}

function cfgFloat(key, def) {
    var v = parseFloat(cfg(key, String(def)));
    return isNaN(v) ? def : v;
}

// ------------------------------------------------------------
// 知识库管理
// ------------------------------------------------------------
var KB = {
    properNouns: {},   // { term: { type, confidence, count, firstSeen, lastSeen, source } }
    characters: {},    // { name: { role, confidence, count, ... } }
    patterns: [],      // 对话模式规则
    pendingReview: []  // 待审核条目
};

var Stats = {
    totalLearned: 0,
    totalCorrections: 0,
    chaptersProcessed: 0,
    aiCalls: 0
};

function loadKB() {
    try {
        var raw = MoRead.storageGet(STORAGE_KEY, "");
        if (raw) {
            var data = JSON.parse(raw);
            KB.properNouns = data.properNouns || {};
            KB.characters = data.characters || {};
            KB.patterns = data.patterns || [];
            KB.pendingReview = data.pendingReview || [];
        }
    } catch (e) {
        MoRead.log("[SmartText] 知识库加载失败: " + e.message);
    }
    try {
        var s = MoRead.storageGet(STATS_KEY, "");
        if (s) Stats = JSON.parse(s);
    } catch (e) {}
}

function saveKB() {
    try {
        MoRead.storageSet(STORAGE_KEY, JSON.stringify({
            properNouns: KB.properNouns,
            characters: KB.characters,
            patterns: KB.patterns,
            pendingReview: KB.pendingReview
        }));
        MoRead.storageSet(STATS_KEY, JSON.stringify(Stats));
    } catch (e) {
        MoRead.log("[SmartText] 知识库保存失败: " + e.message);
    }
}

function addProperNoun(term, type, confidence, source) {
    if (!term || term.length < 1) return;
    var existing = KB.properNouns[term];
    if (existing) {
        existing.count = (existing.count || 0) + 1;
        existing.lastSeen = Date.now();
        if (confidence > (existing.confidence || 0)) {
            existing.confidence = confidence;
        }
        if (type && !existing.type) existing.type = type;
    } else {
        KB.properNouns[term] = {
            type: type || "unknown",
            confidence: confidence || 0.5,
            count: 1,
            firstSeen: Date.now(),
            lastSeen: Date.now(),
            source: source || "heuristic"
        };
        Stats.totalLearned++;
    }
}

function isProperNoun(term) {
    var entry = KB.properNouns[term];
    return entry && entry.confidence >= 0.6;
}

function addCharacter(name, role, confidence, source) {
    if (!name || name.length < 1) return;
    var existing = KB.characters[name];
    if (existing) {
        existing.count = (existing.count || 0) + 1;
        if (confidence > (existing.confidence || 0)) {
            existing.confidence = confidence;
        }
        if (role && !existing.role) existing.role = role;
    } else {
        KB.characters[name] = {
            role: role || "unknown",
            confidence: confidence || 0.5,
            count: 1,
            firstSeen: Date.now(),
            source: source || "heuristic"
        };
        Stats.totalLearned++;
    }
}

function addToPendingReview(item) {
    // 避免重复
    for (var i = 0; i < KB.pendingReview.length; i++) {
        if (KB.pendingReview[i].term === item.term) return;
    }
    KB.pendingReview.push(item);
    // 限制待审核列表大小
    if (KB.pendingReview.length > 200) {
        KB.pendingReview = KB.pendingReview.slice(-200);
    }
}

// ------------------------------------------------------------
// 启发式规则引擎（纯规则，不依赖 AI）
// ------------------------------------------------------------

// 中文姓氏（常见）
var SURNAMES = "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴郁胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍卻璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公";

// 人名后缀（常见名尾字/结构）
var NAME_SUFFIXES = ["儿", "子", "郎", "娘", "哥", "姐", "妹", "爷", "叔", "伯", "姑", "姨"];

// 地名后缀
var PLACE_SUFFIXES = ["山", "峰", "岭", "谷", "洞", "府", "城", "州", "县", "镇", "村", "庄",
    "阁", "殿", "楼", "台", "院", "寺", "观", "庵", "庙",
    "宗", "门", "派", "教", "帮", "会", "盟",
    "江", "河", "湖", "海", "潭", "池", "泉", "溪",
    "岛", "洲", "原", "野", "林", "森", "漠", "滩"];

// 书名/功法名后缀
var TITLE_SUFFIXES = ["录", "记", "传", "诀", "谱", "经", "典", "集", "录", "策", "论", "解",
    "图", "谱", "阵", "法", "术", "功", "式", "剑", "刀", "掌", "指"];

// 对话前缀动词（XX 说道 / XX 问）
var SPEECH_VERBS = ["说", "道", "问", "答", "喊", "叫", "嚷", "吼", "骂", "笑", "哭",
    "冷笑道", "大喝道", "怒喝道", "低声道", "轻声道", "淡淡道", "缓缓道",
    "说道", "问道", "答道", "喊道", "叫道", "笑道", "哭道", "叹道", "惊道",
    "急忙道", "连忙道", "沉声道", "正色道", "摇头道", "点头道",
    "说", "问", "答", "喊", "叫", "骂", "吟", "唱", "念"];

function isChineseChar(ch) {
    return /[\u4e00-\u9fa5]/.test(ch);
}

function isBracketQuote(ch) {
    return ch === "\u300C" || ch === "\u300D" ||  // 「」
           ch === "\u300E" || ch === "\u300F" ||  // 『』
           ch === "\u201C" || ch === "\u201D" ||  // ""
           ch === "\u2018" || ch === "\u2019";    // ''
}

/**
 * 启发式判断「」中的内容是不是对话
 * 返回 { isDialogue: bool, confidence: float, reason: string }
 */
function heuristicIsDialogue(text, start, end) {
    var content = text.substring(start + 1, end - 1); // 去掉引号
    var len = content.length;

    // 空内容
    if (len === 0) return { isDialogue: false, confidence: 0.5, reason: "empty" };

    // 单字 → 极可能不是对话
    if (len === 1) return { isDialogue: false, confidence: 0.9, reason: "single_char" };

    // 2 字 → 可能是人名/地名/短对话，低置信度
    if (len === 2) return { isDialogue: false, confidence: 0.6, reason: "short_2" };

    // 10 字以上 → 大概率是对话
    if (len >= 10) return { isDialogue: true, confidence: 0.8, reason: "long_text" };

    // 查知识库：如果是已知专有名词 → 不是对话
    if (isProperNoun(content)) {
        return { isDialogue: false, confidence: 0.95, reason: "known_proper_noun" };
    }

    // 查知识库：如果是已知角色 → 那要看前后文

    // 后缀判断
    var lastChar = content.charAt(len - 1);
    for (var i = 0; i < PLACE_SUFFIXES.length; i++) {
        if (content.endsWith(PLACE_SUFFIXES[i]) && len <= 5) {
            return { isDialogue: false, confidence: 0.75, reason: "place_suffix:" + PLACE_SUFFIXES[i] };
        }
    }
    for (var j = 0; j < TITLE_SUFFIXES.length; j++) {
        if (content.endsWith(TITLE_SUFFIXES[j]) && len <= 6) {
            return { isDialogue: false, confidence: 0.7, reason: "title_suffix:" + TITLE_SUFFIXES[j] };
        }
    }

    // 前面有说话动词 → 是对话
    var beforeStart = Math.max(0, start - 10);
    var beforeText = text.substring(beforeStart, start);
    for (var k = 0; k < SPEECH_VERBS.length; k++) {
        if (beforeText.indexOf(SPEECH_VERBS[k]) >= 0) {
            return { isDialogue: true, confidence: 0.85, reason: "speech_verb_before:" + SPEECH_VERBS[k] };
        }
    }

    // 内容里有标点符号 → 大概率是对话
    if (/[，。！？、；：]/.test(content)) {
        return { isDialogue: true, confidence: 0.75, reason: "has_punctuation" };
    }

    // 内容全是数字 → 不是对话
    if (/^\d+$/.test(content)) {
        return { isDialogue: false, confidence: 0.9, reason: "all_digits" };
    }

    // 内容含英文 → 大概率不是对话（可能是术语/缩写）
    if (/[a-zA-Z]/.test(content)) {
        return { isDialogue: false, confidence: 0.65, reason: "has_english" };
    }

    // 3-5 字，没有明显特征 → 不确定，低置信度判断为专有名词
    if (len <= 5) {
        return { isDialogue: false, confidence: 0.55, reason: "short_ambiguous" };
    }

    // 默认：6-9 字，无明显特征 → 倾向于是对话
    return { isDialogue: true, confidence: 0.6, reason: "default_mid_length" };
}

/**
 * 从上下文中推断说话人
 */
function inferSpeaker(text, start) {
    var beforeStart = Math.max(0, start - 30);
    var beforeText = text.substring(beforeStart, start);

    // 模式：XXX 说道/问道/...「
    for (var i = 0; i < SPEECH_VERBS.length; i++) {
        var verb = SPEECH_VERBS[i];
        var idx = beforeText.lastIndexOf(verb);
        if (idx >= 0) {
            var namePart = beforeText.substring(0, idx);
            // 提取名字（取最后 2-4 个中文字符）
            var nameMatch = namePart.match(/([\u4e00-\u9fa5]{2,4})$/);
            if (nameMatch) {
                var name = nameMatch[1];
                // 排除常见代词
                var pronouns = ["他", "她", "它", "我", "你", "你们", "他们", "她们", "它们",
                    "有人", "那人", "众人", "大家", "旁白", "女子", "男子", "少年", "少女"];
                if (pronouns.indexOf(name) < 0) {
                    return name;
                }
            }
        }
    }
    return null;
}

// ------------------------------------------------------------
// AI 学习（逐章模式）
// ------------------------------------------------------------

function aiAnalyzeChapter(text, chapterIndex) {
    var mode = cfg("aiMode", "chapter");
    if (mode === "off" || mode === "rules") return;

    var endpoint = cfg("aiEndpoint", "");
    var apiKey = cfg("aiApiKey", "");
    var model = cfg("aiModel", "gpt-4o-mini");

    if (!endpoint || !apiKey) {
        // 没有配置 AI，纯规则模式
        return;
    }

    // 只在逐章模式下实时调用
    if (mode !== "chapter") return;

    // 取前 2000 字做分析（省 token）
    var sample = text.substring(0, Math.min(2000, text.length));

    var prompt = "请分析下面的小说文本片段，提取其中的专有名词和人物。\n" +
        "只返回 JSON，格式：{ \"properNouns\": [{\"term\":\"XXX\",\"type\":\"person|place|organization|title|other\",\"confidence\":0.8}], \"characters\": [{\"name\":\"XXX\",\"role\":\"角色描述\",\"confidence\":0.8}] }\n" +
        "type 取值：person(人名)、place(地名)、organization(门派/组织)、title(书名/功法名)、other(其他)\n" +
        "只提取你有较高把握的，confidence 是 0-1 之间的数字。\n\n" +
        "文本：\n" + sample;

    var body = JSON.stringify({
        model: model,
        messages: [{ role: "user", content: prompt }],
        temperature: 0.3,
        response_format: { type: "json_object" }
    });

    var headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + apiKey
    };

    var baseUrl = endpoint.replace(/\/+$/, "");
    var url = baseUrl + "/v1/chat/completions";

    try {
        var resp = MoRead.httpPost(url, body, "application/json", headers);
        if (!resp || !resp.ok) {
            MoRead.log("[SmartText] AI 调用失败: HTTP " + (resp ? resp.status : "no response"));
            return;
        }

        var data = JSON.parse(resp.body);
        var content = data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
        if (!content) {
            MoRead.log("[SmartText] AI 返回为空");
            return;
        }

        var result = JSON.parse(content);
        var learned = 0;

        if (result.properNouns && result.properNouns.length) {
            for (var i = 0; i < result.properNouns.length; i++) {
                var pn = result.properNouns[i];
                if (pn.term && pn.confidence >= 0.7) {
                    addProperNoun(pn.term, pn.type, pn.confidence, "ai");
                    learned++;
                }
            }
        }

        if (result.characters && result.characters.length) {
            for (var j = 0; j < result.characters.length; j++) {
                var ch = result.characters[j];
                if (ch.name && ch.confidence >= 0.7) {
                    addCharacter(ch.name, ch.role, ch.confidence, "ai");
                    learned++;
                }
            }
        }

        Stats.aiCalls++;
        Stats.chaptersProcessed++;
        saveKB();

        MoRead.log("[SmartText] 第 " + chapterIndex + " 章 AI 分析完成，新学 " + learned + " 条");
    } catch (e) {
        MoRead.log("[SmartText] AI 分析异常: " + e.message);
    }
}

// ------------------------------------------------------------
// 钩子 1: dialogue.segment — 智能对白切分
// ------------------------------------------------------------
function initDialogueSegment() {
    if (!cfgBool("enableDialogueSegment", true)) return;

    MoRead.log("[SmartText] 注册钩子: dialogue.segment");

    MoRead.hook("dialogue.segment", function(p) {
        var text = p.text || "";
        if (!text || text.length < 10) return null;

        var segments = [];
        var cursor = 0;
        var len = text.length;
        var recentSpeaker = null;

        // 找到所有「」对
        var i = 0;
        var dialogueRanges = [];

        // 简单栈式匹配「」
        var stack = [];
        while (i < len) {
            var ch = text.charAt(i);
            if (ch === "\u300C" || ch === "\u300E" || ch === "\u201C" || ch === "\u2018") {
                stack.push({ char: ch, pos: i });
            } else if (ch === "\u300D" || ch === "\u300F" || ch === "\u201D" || ch === "\u2019") {
                if (stack.length > 0) {
                    var top = stack.pop();
                    // 匹配成功
                    if (i > top.pos + 1) {
                        dialogueRanges.push({ start: top.pos, end: i + 1 });
                    }
                }
            }
            i++;
        }

        if (dialogueRanges.length === 0) return null;

        // 按位置排序
        dialogueRanges.sort(function(a, b) { return a.start - b.start; });

        // 生成片段
        for (var k = 0; k < dialogueRanges.length; k++) {
            var range = dialogueRanges[k];

            // 前面的旁白
            if (range.start > cursor) {
                segments.push({
                    start: cursor,
                    end: range.start,
                    role: "\u65C1\u767D",
                    kind: "NARRATION",
                    confidence: 0.95
                });
            }

            // 判断是不是对话
            var result = heuristicIsDialogue(text, range.start, range.end);

            if (result.isDialogue) {
                // 是对话，尝试推断说话人
                var speaker = inferSpeaker(text, range.start);
                if (!speaker && recentSpeaker) {
                    speaker = recentSpeaker;
                }
                if (speaker) {
                    recentSpeaker = speaker;
                    addCharacter(speaker, "", Math.min(0.7, result.confidence), "heuristic");
                }

                segments.push({
                    start: range.start,
                    end: range.end,
                    role: speaker || "\u5BF9\u767D",
                    kind: "DIALOGUE",
                    confidence: result.confidence
                });
            } else {
                // 不是对话，当作专有名词/引用，归为旁白
                var content = text.substring(range.start + 1, range.end - 1);
                if (result.confidence < 0.7) {
                    // 低置信度，加入待审核
                    addToPendingReview({
                        term: content,
                        type: "unknown",
                        confidence: result.confidence,
                        reason: result.reason,
                        context: text.substring(Math.max(0, range.start - 20), Math.min(len, range.end + 20))
                    });
                } else {
                    // 高置信度，加入知识库
                    addProperNoun(content, guessNounType(content, result), result.confidence, "heuristic");
                }

                segments.push({
                    start: range.start,
                    end: range.end,
                    role: "\u65C1\u767D",
                    kind: "NARRATION",
                    confidence: result.confidence
                });
            }

            cursor = range.end;
        }

        // 尾部旁白
        if (cursor < len) {
            segments.push({
                start: cursor,
                end: len,
                role: "\u65C1\u767D",
                kind: "NARRATION",
                confidence: 0.95
            });
        }

        // 保存知识库（异步思维，这里同步保存不影响）
        saveKB();

        return JSON.stringify(segments);
    });
}

// 猜测专有名词类型
function guessNounType(term, result) {
    if (result.reason && result.reason.indexOf("place_suffix") >= 0) return "place";
    if (result.reason && result.reason.indexOf("title_suffix") >= 0) return "title";
    var firstChar = term.charAt(0);
    if (SURNAMES.indexOf(firstChar) >= 0 && term.length >= 2 && term.length <= 4) {
        return "person";
    }
    return "unknown";
}

// ------------------------------------------------------------
// 钩子 2: text.preprocess — TTS 文本优化
// ------------------------------------------------------------
function initTextPreprocess() {
    if (!cfgBool("enableTextPreprocess", true)) return;

    MoRead.log("[SmartText] 注册钩子: text.preprocess");

    MoRead.hook("text.preprocess", function(params) {
        var text = params.text || "";
        if (!text) return null;

        var result = text;
        var changed = false;

        // 已知专有名词：如果被「」括起来，且确认不是对话，去掉「」避免 TTS 切音色
        // （这个逻辑比较复杂，先做简单版：给专有名词加个停顿标记，帮助 TTS 断句）
        // 暂时先不修改，等知识库积累更多后再启用

        if (!changed) return null;
        return result;
    });
}

// ------------------------------------------------------------
// 初始化
// ------------------------------------------------------------
MoRead.log("智能文本理解模块初始化...");

loadKB();

MoRead.log("[SmartText] 知识库加载完成: " +
    Object.keys(KB.properNouns).length + " 专有名词, " +
    Object.keys(KB.characters).length + " 角色, " +
    KB.pendingReview.length + " 待审核");

initDialogueSegment();
initTextPreprocess();

var activeHooks = [];
if (cfgBool("enableDialogueSegment", true)) activeHooks.push("dialogue.segment");
if (cfgBool("enableTextPreprocess", true)) activeHooks.push("text.preprocess");

MoRead.log("智能文本理解模块 v0.1.0 加载完成");
MoRead.log("AI 模式: " + cfg("aiMode", "rules") +
    " | 已激活钩子: " + (activeHooks.length ? activeHooks.join(", ") : "无"));
