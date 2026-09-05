// ============================================================
// 智能文本理解模块 (Smart Text Module) v0.2.0
//
// 核心能力：
//   1. 三层知识库：本书 → 全局 → 启发式规则（优先级从高到低）
//   2. 三态模型：已确认 / 学习中 / 已拒绝
//   3. 双轨学习：AI 逐章学习 + 用户待审核批量确认
//   4. 专有名词识别、对话/引用区分、说话人推断
//
// 注册钩子：
//   - dialogue.segment  智能对白切分
//   - text.preprocess   TTS 文本优化（预留）
//
// 知识库存储结构（storage）：
//   smart_text_books_v1  — 每本书的独立知识库 { bookId: { properNouns, characters } }
//   smart_text_global_v1 — 全局通用知识库
//   smart_text_stats_v1  — 统计数据
//   smart_text_pending_v1 — 待审核列表
// ============================================================

var MODULE_NAME = "smart-text";
var VERSION = "0.2.0";

var STORAGE_BOOKS = "smart_text_books_v1";
var STORAGE_GLOBAL = "smart_text_global_v1";
var STORAGE_STATS = "smart_text_stats_v1";
var STORAGE_PENDING = "smart_text_pending_v1";
var STORAGE_CURRENT_BOOK = "smart_text_current_book";

// 条目状态常量
var STATUS_CONFIRMED = "confirmed";   // 已确认（用户确认过的，最高优先级）
var STATUS_LEARNING = "learning";     // 学习中（AI/规则推断的，直接用但置信度低）
var STATUS_REJECTED = "rejected";     // 已拒绝（用户标记为错的，不再用）

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
// 知识库数据结构
// ------------------------------------------------------------
var GlobalKB = {
    properNouns: {},   // { term: { type, status, confidence, count, firstSeen, lastSeen, source } }
    characters: {},    // { name: { role, status, confidence, count, ... } }
    patterns: []       // 对话模式规则
};

var BookKBs = {};      // { bookId: { properNouns: {}, characters: {} } }

var currentBookId = 0;
var pendingReview = []; // [{ term, type, status, confidence, reason, context, bookId }]

var Stats = {
    totalLearned: 0,
    totalCorrections: 0,
    chaptersProcessed: 0,
    aiCalls: 0,
    confirmedCount: 0,
    learningCount: 0,
    rejectedCount: 0
};

// ------------------------------------------------------------
// 知识库加载 / 保存
// ------------------------------------------------------------
function loadAllKB() {
    try {
        var g = MoRead.storageGet(STORAGE_GLOBAL, "");
        if (g) {
            var gd = JSON.parse(g);
            GlobalKB.properNouns = gd.properNouns || {};
            GlobalKB.characters = gd.characters || {};
            GlobalKB.patterns = gd.patterns || [];
        }
    } catch (e) {
        MoRead.log("[SmartText] 全局知识库加载失败: " + e.message);
    }
    try {
        var b = MoRead.storageGet(STORAGE_BOOKS, "");
        if (b) BookKBs = JSON.parse(b);
    } catch (e) {
        MoRead.log("[SmartText] 本书知识库加载失败: " + e.message);
    }
    try {
        var p = MoRead.storageGet(STORAGE_PENDING, "");
        if (p) pendingReview = JSON.parse(p);
    } catch (e) {}
    try {
        var s = MoRead.storageGet(STORAGE_STATS, "");
        if (s) Stats = JSON.parse(s);
    } catch (e) {}
    try {
        currentBookId = parseInt(MoRead.storageGet(STORAGE_CURRENT_BOOK, "0"), 10) || 0;
    } catch (e) {}
}

function saveGlobalKB() {
    try {
        MoRead.storageSet(STORAGE_GLOBAL, JSON.stringify({
            properNouns: GlobalKB.properNouns,
            characters: GlobalKB.characters,
            patterns: GlobalKB.patterns
        }));
    } catch (e) {
        MoRead.log("[SmartText] 全局知识库保存失败: " + e.message);
    }
}

function saveBooksKB() {
    try {
        MoRead.storageSet(STORAGE_BOOKS, JSON.stringify(BookKBs));
    } catch (e) {
        MoRead.log("[SmartText] 本书知识库保存失败: " + e.message);
    }
}

function savePending() {
    try {
        // 限制大小
        if (pendingReview.length > 500) {
            pendingReview = pendingReview.slice(-500);
        }
        MoRead.storageSet(STORAGE_PENDING, JSON.stringify(pendingReview));
    } catch (e) {}
}

function saveStats() {
    try {
        MoRead.storageSet(STORAGE_STATS, JSON.stringify(Stats));
    } catch (e) {}
}

function saveAll() {
    saveGlobalKB();
    saveBooksKB();
    savePending();
    saveStats();
}

function setCurrentBook(bookId) {
    bookId = parseInt(bookId, 10) || 0;
    if (bookId > 0 && bookId !== currentBookId) {
        currentBookId = bookId;
        MoRead.storageSet(STORAGE_CURRENT_BOOK, String(bookId));
    }
    return bookId;
}

// 获取当前书的知识库（没有就创建）
function getBookKB(bookId) {
    bookId = String(bookId);
    if (!BookKBs[bookId]) {
        BookKBs[bookId] = {
            properNouns: {},
            characters: {}
        };
    }
    return BookKBs[bookId];
}

// ------------------------------------------------------------
// 知识库查询（三层查找）
// ------------------------------------------------------------

/**
 * 查找专有名词，按优先级：本书 → 全局
 * 返回：{ found: bool, type, status, confidence, source }
 */
function lookupProperNoun(term, bookId) {
    // 1. 查本书知识库
    var bookKB = bookId ? getBookKB(bookId) : null;
    if (bookKB && bookKB.properNouns[term]) {
        var be = bookKB.properNouns[term];
        return { found: true, level: "book", type: be.type, status: be.status, confidence: be.confidence, source: be.source };
    }

    // 2. 查全局知识库
    if (GlobalKB.properNouns[term]) {
        var ge = GlobalKB.properNouns[term];
        return { found: true, level: "global", type: ge.type, status: ge.status, confidence: ge.confidence, source: ge.source };
    }

    return { found: false };
}

/**
 * 查找角色
 */
function lookupCharacter(name, bookId) {
    var bookKB = bookId ? getBookKB(bookId) : null;
    if (bookKB && bookKB.characters[name]) {
        var be = bookKB.characters[name];
        return { found: true, level: "book", role: be.role, status: be.status, confidence: be.confidence };
    }
    if (GlobalKB.characters[name]) {
        var ge = GlobalKB.characters[name];
        return { found: true, level: "global", role: ge.role, status: ge.status, confidence: ge.confidence };
    }
    return { found: false };
}

// ------------------------------------------------------------
// 知识库写入
// ------------------------------------------------------------

/**
 * 添加/更新专有名词
 * @param level "book" | "global"
 * @param status STATUS_CONFIRMED | STATUS_LEARNING | STATUS_REJECTED
 */
function addProperNoun(term, type, confidence, source, level, status, bookId) {
    if (!term || term.length < 1) return;
    level = level || "global";
    status = status || STATUS_LEARNING;

    var target;
    if (level === "book" && bookId) {
        target = getBookKB(bookId).properNouns;
    } else {
        target = GlobalKB.properNouns;
    }

    var existing = target[term];
    if (existing) {
        existing.count = (existing.count || 0) + 1;
        existing.lastSeen = Date.now();
        // 只有新状态"更强"时才升级
        if (status === STATUS_CONFIRMED && existing.status !== STATUS_CONFIRMED) {
            existing.status = STATUS_CONFIRMED;
            existing.confidence = Math.max(existing.confidence || 0, confidence || 0.9);
            if (type && !existing.type) existing.type = type;
        } else if (status === STATUS_LEARNING && existing.status === STATUS_REJECTED) {
            // 已拒绝的不降级
        } else if (confidence > (existing.confidence || 0)) {
            existing.confidence = confidence;
        }
        if (type && !existing.type) existing.type = type;
    } else {
        target[term] = {
            type: type || "unknown",
            status: status,
            confidence: confidence || 0.5,
            count: 1,
            firstSeen: Date.now(),
            lastSeen: Date.now(),
            source: source || "unknown"
        };
        Stats.totalLearned++;
        if (status === STATUS_CONFIRMED) Stats.confirmedCount++;
        else if (status === STATUS_LEARNING) Stats.learningCount++;
        else if (status === STATUS_REJECTED) Stats.rejectedCount++;
    }
}

function addCharacter(name, role, confidence, source, level, status, bookId) {
    if (!name || name.length < 1) return;
    level = level || "global";
    status = status || STATUS_LEARNING;

    var target;
    if (level === "book" && bookId) {
        target = getBookKB(bookId).characters;
    } else {
        target = GlobalKB.characters;
    }

    var existing = target[name];
    if (existing) {
        existing.count = (existing.count || 0) + 1;
        if (status === STATUS_CONFIRMED && existing.status !== STATUS_CONFIRMED) {
            existing.status = STATUS_CONFIRMED;
            existing.confidence = Math.max(existing.confidence || 0, confidence || 0.9);
            if (role && !existing.role) existing.role = role;
        } else if (confidence > (existing.confidence || 0)) {
            existing.confidence = confidence;
        }
        if (role && !existing.role) existing.role = role;
    } else {
        target[name] = {
            role: role || "unknown",
            status: status,
            confidence: confidence || 0.5,
            count: 1,
            firstSeen: Date.now(),
            source: source || "unknown"
        };
        Stats.totalLearned++;
        if (status === STATUS_CONFIRMED) Stats.confirmedCount++;
        else if (status === STATUS_LEARNING) Stats.learningCount++;
    }
}

/**
 * 加入待审核列表
 */
function addToPendingReview(item) {
    if (!item || !item.term) return;
    // 去重
    for (var i = 0; i < pendingReview.length; i++) {
        if (pendingReview[i].term === item.term && pendingReview[i].bookId === item.bookId) {
            // 更新置信度和上下文
            pendingReview[i].confidence = Math.max(pendingReview[i].confidence || 0, item.confidence || 0);
            return;
        }
    }
    pendingReview.push(item);
    // 限制大小（savePending 里也会限制，这里先防内存）
    if (pendingReview.length > 600) {
        pendingReview = pendingReview.slice(-500);
    }
}

// ------------------------------------------------------------
// 启发式规则引擎（纯规则，兜底）
// ------------------------------------------------------------

var SURNAMES = "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴郁胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍卻璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公";

var PLACE_SUFFIXES = ["山", "峰", "岭", "谷", "洞", "府", "城", "州", "县", "镇", "村", "庄",
    "阁", "殿", "楼", "台", "院", "寺", "观", "庵", "庙",
    "宗", "门", "派", "教", "帮", "会", "盟",
    "江", "河", "湖", "海", "潭", "池", "泉", "溪",
    "岛", "洲", "原", "野", "林", "森", "漠", "滩"];

var TITLE_SUFFIXES = ["录", "记", "传", "诀", "谱", "经", "典", "集", "录", "策", "论", "解",
    "图", "谱", "阵", "法", "术", "功", "式", "剑", "刀", "掌", "指"];

var SPEECH_VERBS = ["冷笑道", "大喝道", "怒喝道", "低声道", "轻声道", "淡淡道", "缓缓道",
    "说道", "问道", "答道", "喊道", "叫道", "笑道", "哭道", "叹道", "惊道",
    "急忙道", "连忙道", "沉声道", "正色道", "摇头道", "点头道",
    "说", "道", "问", "答", "喊", "叫", "骂", "吟", "唱", "念"];

var PRONOUNS = ["他", "她", "它", "我", "你", "你们", "他们", "她们", "它们",
    "有人", "那人", "众人", "大家", "旁白", "女子", "男子", "少年", "少女",
    "一个", "两个", "三人", "有人", "一人", "此人", "彼人"];

/**
 * 启发式判断「」中的内容是不是对话
 * 返回 { isDialogue: bool, confidence: float, reason: string, guessedType: string }
 */
function heuristicIsDialogue(text, start, end) {
    var content = text.substring(start + 1, end - 1);
    var len = content.length;

    if (len === 0) return { isDialogue: false, confidence: 0.5, reason: "empty", guessedType: "unknown" };
    if (len === 1) return { isDialogue: false, confidence: 0.9, reason: "single_char", guessedType: "unknown" };
    if (len >= 15) return { isDialogue: true, confidence: 0.85, reason: "long_text", guessedType: "dialogue" };

    // 后缀判断
    for (var i = 0; i < PLACE_SUFFIXES.length; i++) {
        if (content.endsWith(PLACE_SUFFIXES[i]) && len <= 6) {
            return { isDialogue: false, confidence: 0.75, reason: "place_suffix", guessedType: "place" };
        }
    }
    for (var j = 0; j < TITLE_SUFFIXES.length; j++) {
        if (content.endsWith(TITLE_SUFFIXES[j]) && len <= 6) {
            return { isDialogue: false, confidence: 0.7, reason: "title_suffix", guessedType: "title" };
        }
    }

    // 前面有说话动词 → 是对话
    var beforeStart = Math.max(0, start - 15);
    var beforeText = text.substring(beforeStart, start);
    for (var k = 0; k < SPEECH_VERBS.length; k++) {
        if (beforeText.indexOf(SPEECH_VERBS[k]) >= 0) {
            return { isDialogue: true, confidence: 0.88, reason: "speech_verb_before", guessedType: "dialogue" };
        }
    }

    // 内容里有标点 → 大概率是对话
    if (/[，。！？、；：…—]/.test(content)) {
        return { isDialogue: true, confidence: 0.78, reason: "has_punctuation", guessedType: "dialogue" };
    }

    // 全是数字 → 不是对话
    if (/^\d+$/.test(content)) {
        return { isDialogue: false, confidence: 0.9, reason: "all_digits", guessedType: "other" };
    }

    // 含英文 → 大概率不是对话
    if (/[a-zA-Z]/.test(content)) {
        return { isDialogue: false, confidence: 0.65, reason: "has_english", guessedType: "other" };
    }

    // 2 字 + 第一个字是常见姓氏 → 可能是人名
    if (len === 2 || len === 3) {
        var firstChar = content.charAt(0);
        if (SURNAMES.indexOf(firstChar) >= 0) {
            return { isDialogue: false, confidence: 0.6, reason: "likely_name", guessedType: "person" };
        }
    }

    // 短内容（2-5字）无明显特征 → 倾向专有名词，低置信度
    if (len <= 5) {
        return { isDialogue: false, confidence: 0.55, reason: "short_ambiguous", guessedType: "unknown" };
    }

    // 6-14 字，无明显特征 → 倾向于是对话
    return { isDialogue: true, confidence: 0.6, reason: "default_mid_length", guessedType: "dialogue" };
}

/**
 * 从上下文中推断说话人
 */
function inferSpeaker(text, start) {
    var beforeStart = Math.max(0, start - 35);
    var beforeText = text.substring(beforeStart, start);

    for (var i = 0; i < SPEECH_VERBS.length; i++) {
        var verb = SPEECH_VERBS[i];
        var idx = beforeText.lastIndexOf(verb);
        if (idx >= 0) {
            var namePart = beforeText.substring(0, idx);
            var nameMatch = namePart.match(/([\u4e00-\u9fa5]{1,4})$/);
            if (nameMatch) {
                var name = nameMatch[1];
                if (PRONOUNS.indexOf(name) < 0 && name.length >= 2) {
                    return name;
                }
            }
        }
    }
    return null;
}

// 猜测专有名词类型
function guessNounType(content, heuristicResult) {
    if (heuristicResult.guessedType && heuristicResult.guessedType !== "dialogue") {
        return heuristicResult.guessedType;
    }
    var firstChar = content.charAt(0);
    if (SURNAMES.indexOf(firstChar) >= 0 && content.length >= 2 && content.length <= 4) {
        return "person";
    }
    return "unknown";
}

// ------------------------------------------------------------
// AI 逐章学习
// ------------------------------------------------------------

function aiAnalyzeChapter(text, bookId, chapterIndex) {
    var mode = cfg("aiMode", "rules");
    if (mode === "off" || mode === "rules") return;
    if (mode !== "chapter") return; // 目前只实现逐章模式

    var provider = cfg("aiProvider", "native");

    // 每章取前 2000 字
    var sample = text.substring(0, Math.min(2000, text.length));
    if (sample.length < 100) return;

    var systemPrompt = "你是小说文本分析专家。分析下面的小说片段，提取专有名词和人物角色。\n" +
        "只返回 JSON 格式：{\"properNouns\": [{\"term\":\"XXX\",\"type\":\"person|place|organization|title|other\",\"confidence\":0.8}], \"characters\": [{\"name\":\"XXX\",\"role\":\"角色身份\",\"confidence\":0.8}] }\n" +
        "type：person(人名) place(地名) organization(门派/组织/公司) title(书名/功法/宝物) other(其他)\n" +
        "只提取你比较确定的，confidence 0-1。";

    var userPrompt = "片段：\n" + sample;

    var content = null;

    try {
        if (provider === "native") {
            // 使用原生配置好的 AI（推荐，自动复用所有供应商）
            var aiRole = cfg("aiRole", "CHEAP");
            content = MoRead.aiChat(systemPrompt, userPrompt, aiRole);
        } else {
            // 自定义 HTTP 模式（兼容旧版）
            var endpoint = cfg("aiEndpoint", "");
            var apiKey = cfg("aiApiKey", "");
            var model = cfg("aiModel", "gpt-4o-mini");
            if (!endpoint || !apiKey) return;

            var body = JSON.stringify({
                model: model,
                messages: [
                    { role: "system", content: systemPrompt },
                    { role: "user", content: userPrompt }
                ],
                temperature: 0.3,
                response_format: { type: "json_object" }
            });

            var headers = {
                "Content-Type": "application/json",
                "Authorization": "Bearer " + apiKey
            };

            var baseUrl = endpoint.replace(/\/+$/, "");
            var url = baseUrl + "/v1/chat/completions";

            var resp = MoRead.httpPost(url, body, "application/json", headers);
            if (!resp || !resp.ok) {
                MoRead.log("[SmartText] AI 调用失败: HTTP " + (resp ? resp.status : "no response"));
                return;
            }

            var data = JSON.parse(resp.body);
            content = data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
        }

        if (!content) {
            MoRead.log("[SmartText] AI 返回为空");
            return;
        }

        var result = JSON.parse(content);
        var learned = 0;

        if (result.properNouns && result.properNouns.length) {
            for (var i = 0; i < result.properNouns.length; i++) {
                var pn = result.properNouns[i];
                if (pn.term && pn.confidence >= 0.6) {
                    // AI 学的都进本书知识库（学习中状态）
                    addProperNoun(pn.term, pn.type, pn.confidence, "ai", "book", STATUS_LEARNING, bookId);
                    learned++;
                    // 低置信度的同时加入待审核
                    if (pn.confidence < 0.85) {
                        addToPendingReview({
                            term: pn.term,
                            type: pn.type,
                            confidence: pn.confidence,
                            source: "ai",
                            bookId: bookId || 0,
                            chapterIndex: chapterIndex || 0
                        });
                    }
                }
            }
        }

        if (result.characters && result.characters.length) {
            for (var j = 0; j < result.characters.length; j++) {
                var ch = result.characters[j];
                if (ch.name && ch.confidence >= 0.6) {
                    addCharacter(ch.name, ch.role, ch.confidence, "ai", "book", STATUS_LEARNING, bookId);
                    learned++;
                }
            }
        }

        Stats.aiCalls++;
        Stats.chaptersProcessed++;
        saveAll();

        MoRead.log("[SmartText] 第" + (chapterIndex + 1) + "章 AI 分析: 新学 " + learned + " 条(本书库)");
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

        var bookId = p.bookId ? parseInt(p.bookId, 10) : currentBookId || 0;
        var chapterIndex = p.chapterIndex ? parseInt(p.chapterIndex, 10) : 0;
        if (bookId > 0) setCurrentBook(bookId);

        var segments = [];
        var cursor = 0;
        var len = text.length;
        var recentSpeaker = null;

        // 找到所有引号对（支持「」『』""''）
        var pairs = {
            "\u300C": "\u300D",  // 「」
            "\u300E": "\u300F",  // 『』
            "\u201C": "\u201D",  // ""
            "\u2018": "\u2019"   // ''
        };
        var stack = [];
        var dialogueRanges = [];
        var i = 0;

        while (i < len) {
            var ch = text.charAt(i);
            // 开引号
            if (pairs[ch]) {
                stack.push({ char: ch, pos: i });
            } else {
                // 检查是不是闭引号
                var found = -1;
                for (var s = stack.length - 1; s >= 0; s--) {
                    if (pairs[stack[s].char] === ch) {
                        found = s;
                        break;
                    }
                }
                if (found >= 0) {
                    var top = stack.splice(found, 1)[0];
                    if (i > top.pos + 1) {
                        dialogueRanges.push({ start: top.pos, end: i + 1 });
                    }
                }
            }

            // 直引号（" 和 '）的特殊处理：配对
            if (ch === '"' || ch === "'") {
                // 已经在上面的 pairs 里处理了，这里空跑
            }

            i++;
        }

        if (dialogueRanges.length === 0) {
            // 没有引号，也触发一下 AI 学习（如果是逐章模式）
            if (bookId > 0) aiAnalyzeChapter(text, bookId, chapterIndex);
            return null;
        }

        dialogueRanges.sort(function(a, b) { return a.start - b.start; });

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

            var content = text.substring(range.start + 1, range.end - 1);

            // ── 三层查找 ──
            var lookup = lookupProperNoun(content, bookId);
            var isDialogue = true;
            var confidence = 0.5;
            var reason = "";

            if (lookup.found && lookup.status !== STATUS_REJECTED) {
                // 知识库有，且不是被拒绝的 → 不是对话
                isDialogue = false;
                confidence = lookup.status === STATUS_CONFIRMED ? 0.98 : lookup.confidence;
                reason = "kb_" + lookup.level;
            } else if (lookup.found && lookup.status === STATUS_REJECTED) {
                // 被拒绝的专有名词 → 就是对话
                isDialogue = true;
                confidence = 0.8;
                reason = "kb_rejected";
            } else {
                // 知识库没有 → 用启发式
                var h = heuristicIsDialogue(text, range.start, range.end);
                isDialogue = h.isDialogue;
                confidence = h.confidence;
                reason = "heuristic:" + h.reason;

                // 启发式判断为专有名词的，加入学习（本书库）
                if (!isDialogue && content.length >= 2 && content.length <= 6) {
                    var nounType = guessNounType(content, h);
                    addProperNoun(content, nounType, h.confidence, "heuristic", "book", STATUS_LEARNING, bookId);
                    // 低置信度的进待审核
                    if (h.confidence < 0.75) {
                        var ctx = text.substring(Math.max(0, range.start - 20), Math.min(len, range.end + 20));
                        addToPendingReview({
                            term: content,
                            type: nounType,
                            confidence: h.confidence,
                            reason: h.reason,
                            context: ctx,
                            source: "heuristic",
                            bookId: bookId || 0,
                            chapterIndex: chapterIndex
                        });
                    }
                }
            }

            if (isDialogue) {
                // 对话：推断说话人
                var speaker = inferSpeaker(text, range.start);
                if (!speaker && recentSpeaker) speaker = recentSpeaker;

                // 查角色库确认
                if (speaker) {
                    var charLookup = lookupCharacter(speaker, bookId);
                    if (charLookup.found && charLookup.status === STATUS_REJECTED) {
                        speaker = null; // 被拒绝的名字，不当说话人
                    } else if (charLookup.found) {
                        recentSpeaker = speaker;
                    } else {
                        // 新发现的说话人，加入学习
                        addCharacter(speaker, "", 0.6, "heuristic", "book", STATUS_LEARNING, bookId);
                        recentSpeaker = speaker;
                    }
                }

                segments.push({
                    start: range.start,
                    end: range.end,
                    role: speaker || "\u5BF9\u767D",
                    kind: "DIALOGUE",
                    confidence: confidence
                });
            } else {
                // 专有名词/引用：归为旁白
                segments.push({
                    start: range.start,
                    end: range.end,
                    role: "\u65C1\u767D",
                    kind: "NARRATION",
                    confidence: confidence
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

        // AI 逐章学习（异步思维，同步调用但耗时不长）
        if (bookId > 0 && chapterIndex % 3 === 0) {
            // 每 3 章调用一次 AI，省 token
            aiAnalyzeChapter(text, bookId, chapterIndex);
        }

        saveAll();
        return JSON.stringify(segments);
    });
}

// ------------------------------------------------------------
// 钩子 2: text.preprocess — TTS 文本优化（预留）
// ------------------------------------------------------------
function initTextPreprocess() {
    if (!cfgBool("enableTextPreprocess", true)) return;

    MoRead.log("[SmartText] 注册钩子: text.preprocess (预留)");

    MoRead.hook("text.preprocess", function(params) {
        // 预留：TTS 时专有名词处理
        // 暂时不做修改
        return null;
    });
}

// ------------------------------------------------------------
// 初始化
// ------------------------------------------------------------
MoRead.log("智能文本理解模块初始化...");

loadAllKB();

var bookCount = Object.keys(BookKBs).length;
var globalPN = Object.keys(GlobalKB.properNouns).length;
var globalCH = Object.keys(GlobalKB.characters).length;

MoRead.log("[SmartText] 知识库: 全局 " + globalPN + " 名词/" + globalCH + " 角色, " +
    bookCount + " 本书, " + pendingReview.length + " 待审核");

initDialogueSegment();
initTextPreprocess();

var activeHooks = [];
if (cfgBool("enableDialogueSegment", true)) activeHooks.push("dialogue.segment");
if (cfgBool("enableTextPreprocess", true)) activeHooks.push("text.preprocess");

MoRead.log("智能文本理解模块 v" + VERSION + " 加载完成");
MoRead.log("AI 模式: " + cfg("aiMode", "rules") +
    " | 钩子: " + (activeHooks.length ? activeHooks.join(", ") : "无"));
