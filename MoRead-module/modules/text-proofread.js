// ============================================================
// 文本精校模块 (Text Proofread Module) v1.1.0
//
// 注册两个 hook:
//   - text.display:    修改显示的文本（阅读器渲染前）
//   - text.preprocess: 修改 TTS 朗读的文本（合成前）
//
// 规则列表:
//   1. 全角数字转半角
//   2. 全角字母转半角
//   3. 半角中文标点转全角（智能识别中文上下文）
//   4. 引号规范化（弯引号 / 直引号 → 中文引号）
//   5. 省略号规范化（... → ……）
//   6. 合并重复标点
//   7. 清理多余空白
//   8. 合并多余空行
//   9. 常见错别字替换
//  10. 自定义替换（支持普通替换和正则替换）
// ============================================================

var MODULE_NAME = "text-proofread";
var changeCount = 0;

// ------------------------------------------------------------
// 工具函数
// ------------------------------------------------------------
function isEnabled(key) {
    return MoRead.configGet(key, "true") === "true";
}

function inc() {
    changeCount++;
}

// ------------------------------------------------------------
// 规则 1: 全角数字转半角
// ------------------------------------------------------------
function fullwidthNumToHalfwidth(text) {
    if (!isEnabled("ruleFullwidthNum")) return text;
    var result = text.replace(/[\uFF10-\uFF19]/g, function(ch) {
        return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0);
    });
    if (result !== text) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 2: 全角字母转半角
// ------------------------------------------------------------
function fullwidthLetterToHalfwidth(text) {
    if (!isEnabled("ruleFullwidthLetter")) return text;
    var result = text.replace(/[\uFF21-\uFF3A\uFF41-\uFF5A]/g, function(ch) {
        return String.fromCharCode(ch.charCodeAt(0) - 0xFEE0);
    });
    if (result !== text) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 3: 半角标点转全角（中文上下文）
// ------------------------------------------------------------
function halfwidthPunctToFullwidth(text) {
    if (!isEnabled("ruleHalfwidthPunct")) return text;
    var map = {
        ",": "\uFF0C",   // ，
        ".": "\u3002",   // 。
        "!": "\uFF01",   // ！
        "?": "\uFF1F",   // ？
        ";": "\uFF1B",   // ；
        ":": "\uFF1A",   // ：
        "(": "\uFF08",   // （
        ")": "\uFF09"    // ）
    };
    // 中文上下文：前后有中文字符、中文标点或行首行尾
    var cnChar = "[\u4e00-\u9fa5\u3000-\u303F\uFF00-\uFFEF]";
    var result = text;
    var changed = false;

    // 前有中文 + 半角标点 + 后有中文/空白/行尾
    var re = new RegExp("(" + cnChar + ")([,.!?;:()])(?=" + cnChar + "|\\s|$)", "g");
    result = result.replace(re, function(match, cn, punct) {
        if (map[punct]) {
            changed = true;
            return cn + map[punct];
        }
        return match;
    });

    // 行首的半角标点 + 后面紧跟中文
    var re2 = new RegExp("(^|\\n)([,.!?;:()])(?=" + cnChar + ")", "g");
    result = result.replace(re2, function(match, prefix, punct) {
        if (map[punct]) {
            changed = true;
            return prefix + map[punct];
        }
        return match;
    });

    if (changed) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 4: 引号规范化
// ------------------------------------------------------------
function normalizeQuotes(text) {
    if (!isEnabled("ruleQuotes")) return text;
    var result = text;
    var changed = false;

    // 弯引号（smart quotes）→ 中文引号
    // U+201C " LEFT DOUBLE QUOTATION MARK  → 保留为中文左双引号
    // U+201D " RIGHT DOUBLE QUOTATION MARK → 保留为中文右双引号
    // U+2018 ' LEFT SINGLE QUOTATION MARK  → 保留为中文左单引号
    // U+2019 ' RIGHT SINGLE QUOTATION MARK → 保留为中文右单引号
    // （这些 Unicode 码点本身就是标准中文引号，不需要转）

    // 直双引号 " → 中文双引号（成对匹配，交替分配左右）
    var inDouble = false;
    result = result.replace(/"/g, function() {
        inDouble = !inDouble;
        changed = true;
        return inDouble ? "\u201C" : "\u201D";
    });

    // 直单引号 ' → 中文单引号（成对匹配）
    // 注意：英文缩写中的 ' （如 don't）可能被误判，但中文文本中较少见
    var inSingle = false;
    result = result.replace(/'/g, function() {
        inSingle = !inSingle;
        changed = true;
        return inSingle ? "\u2018" : "\u2019";
    });

    // 中文直角引号「」→ 弯引号「统一风格」
    // （保留原样，因为有些用户偏好直角引号，这里不强制转换）

    if (changed) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 5: 省略号规范化
// ------------------------------------------------------------
function normalizeEllipsis(text) {
    if (!isEnabled("ruleEllipsis")) return text;
    var result = text;
    var changed = false;

    // 三个或更多半角点 → 中文省略号
    if (/\.{3,}/.test(result)) {
        result = result.replace(/\.{3,}/g, "\u2026\u2026");
        changed = true;
    }

    // 单个省略号 → 双省略号（中文规范）
    // 注意：Rhino 不支持后行断言，用替换法实现
    // 先把双省略号替换成占位符，再把单省略号替换成双，最后还原占位符
    if (/\u2026/.test(result)) {
        var PLACEHOLDER = "\uE000\uE001"; // 私有区字符做占位符
        result = result.replace(/\u2026\u2026/g, PLACEHOLDER);
        result = result.replace(/\u2026/g, "\u2026\u2026");
        result = result.replace(new RegExp(PLACEHOLDER, "g"), "\u2026\u2026");
        changed = true;
    }

    // 三个或更多中文省略号 → 保留两个
    if (/\u2026{3,}/.test(result)) {
        result = result.replace(/\u2026{3,}/g, "\u2026\u2026");
        changed = true;
    }

    if (changed) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 6: 合并重复标点
// ------------------------------------------------------------
function collapseRepeatedPunctuation(text) {
    if (!isEnabled("ruleCollapsePunct")) return text;
    var result = text;
    var changed = false;

    // 重复的中文标点（逗号句号感叹号问号分号冒号顿号）→ 保留两个
    var re = /([\uFF0C\u3002\uFF01\uFF1F\uFF1B\uFF1A\u3001])\1{2,}/g;
    if (re.test(result)) {
        result = result.replace(re, "$1$1");
        changed = true;
    }

    // 重复的 ?! 混合 → 标准化为 ?!
    if (/[!?]{3,}/.test(result)) {
        result = result.replace(/[!?]{3,}/g, "?!");
        changed = true;
    }

    // 重复的 ~ 或 - → 保留两个
    if (/~{3,}/.test(result)) {
        result = result.replace(/~{3,}/g, "~~");
        changed = true;
    }

    if (changed) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 7: 清理多余空白
// ------------------------------------------------------------
function trimWhitespace(text) {
    if (!isEnabled("ruleTrimWhitespace")) return text;
    var result = text;
    var changed = false;

    // 行首行尾空白
    if (/^[ \t]+|[ \t]+$/m.test(result)) {
        result = result.replace(/^[ \t]+|[ \t]+$/gm, "");
        changed = true;
    }

    // 中文之间的空格 → 去掉
    if (/[\u4e00-\u9fa5][ \t]+[\u4e00-\u9fa5]/.test(result)) {
        result = result.replace(/([\u4e00-\u9fa5])[ \t]+([\u4e00-\u9fa5])/g, "$1$2");
        changed = true;
    }

    // 英文/数字之间的多个空格 → 单个空格
    if (/[a-zA-Z0-9]  +[a-zA-Z0-9]/.test(result)) {
        result = result.replace(/([a-zA-Z0-9])[ ]{2,}([a-zA-Z0-9])/g, "$1 $2");
        changed = true;
    }

    // 中文与英文/数字之间保留一个空格（可选，默认关闭，这里不做）
    // 因为有些排版风格不需要这个空格

    if (changed) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 8: 合并多余空行
// ------------------------------------------------------------
function collapseNewlines(text) {
    if (!isEnabled("ruleCollapseNewlines")) return text;
    if (!/\n{3,}/.test(text)) return text;
    var result = text.replace(/\n{3,}/g, "\n\n");
    inc();
    return result;
}

// ------------------------------------------------------------
// 规则 9: 常见错别字替换
// ------------------------------------------------------------
var commonTypos = [
    // 常见易混淆词
    ["好象", "好像"],
    ["其它", "其他"],
    ["做为", "作为"],
    ["作梦", "做梦"],
    ["缘份", "缘分"],
    ["座落", "坐落"],
    ["帐户", "账户"],
    ["帐蓬", "帐篷"],
    ["年青", "年轻"],
    ["成份", "成分"],
    ["身分", "身份"],
    ["部份", "部分"],
    ["按排", "安排"],
    ["报歉", "抱歉"],
    ["必竟", "毕竟"],
    ["辨论", "辩论"],
    ["部置", "布置"],
    ["苍桑", "沧桑"],
    ["差使", "差事"],
    ["谗言", "谗言"],
    ["彻底", "彻底"],
    ["称颂", "称颂"],
    ["串插", "穿插"],
    ["殆工", "怠工"],
    ["担搁", "耽搁"],
    ["倒乱", "捣乱"],
    ["凋蔽", "凋敝"],
    ["迭起", "迭起"],
    ["赌搏", "赌博"],
    ["防碍", "妨碍"],
    ["废解", "费解"],
    ["俯看", "俯瞰"],
    ["杆秤", "杆秤"],
    ["告磬", "告罄"],
    ["跟本", "根本"],
    ["工效", "功效"],
    ["诟骂", "诟骂"],
    ["蛊或", "蛊惑"],
    ["刮躁", "聒噪"],
    ["贯输", "灌输"],
    ["鬼计", "诡计"],
    ["寒喧", "寒暄"],
    ["号淘", "号啕"],
    ["喝采", "喝彩"],
    ["哄响", "轰响"],
    ["宏亮", "洪亮"],
    ["换散", "涣散"],
    ["谎诞", "荒诞"],
    ["恢谐", "诙谐"],
    ["缉拿", "缉拿"],
    ["即然", "既然"],
    ["技俩", "伎俩"],
    ["坚苦", "艰苦"],
    ["艰定", "坚定"],
    ["俭仆", "俭朴"],
    ["娇健", "矫健"],
    ["脚指", "脚趾"],
    ["接恰", "接洽"],
    ["竭见", "谒见"],
    ["尽然", "竟然"],
    ["就序", "就绪"],
    ["局布", "局部"],
    ["决窍", "诀窍"],
    ["竣工", "竣工"],
    ["楷书", "楷书"],
    ["垦求", "恳求"],
    ["枯躁", "枯燥"],
    ["宽敝", "宽敞"],
    ["阑跚", "蹒跚"],
    ["狼籍", "狼藉"],
    ["老炼", "老练"],
    ["冷寞", "冷漠"],
    ["礼上往来", "礼尚往来"],
    ["连袂", "联袂"],
    ["撩绕", "缭绕"],
    ["了望", "瞭望"],
    ["灵俐", "伶俐"],
    ["流恋", "留恋"],
    ["脉博", "脉搏"],
    ["慢不经心", "漫不经心"],
    ["冒然", "贸然"],
    ["门坎", "门槛"],
    ["迷漫", "弥漫"],
    ["免强", "勉强"],
    ["明察秋豪", "明察秋毫"],
    ["磨挲", "摩挲"],
    ["默守成规", "墨守成规"],
    ["目不交捷", "目不交睫"],
    ["衲闷", "纳闷"],
    ["脑怒", "恼怒"],
    ["内哄", "内讧"],
    ["拈污", "玷污"],
    ["蘖根", "孽根"],
    ["欧打", "殴打"],
    ["攀蹬", "攀登"],
    ["盘据", "盘踞"],
    ["赔尝", "赔偿"],
    ["披糜", "披靡"],
    ["偏面", "片面"],
    ["飘流", "漂流"],
    ["凭添", "平添"],
    ["迫不急待", "迫不及待"],
    ["凄残", "凄惨"],
    ["气慨", "气概"],
    ["恰谈", "洽谈"],
    ["牵就", "迁就"],
    ["遣责", "谴责"],
    ["欠收", "歉收"],
    ["敲榨", "敲诈"],
    ["亲怩", "亲昵"],
    ["青徕", "青睐"],
    ["清彻", "清澈"],
    ["顷家荡产", "倾家荡产"],
    ["曲指可数", "屈指可数"],
    ["全愈", "痊愈"],
    ["群贤必至", "群贤毕至"],
    ["融汇", "融会"],
    ["融恰", "融洽"],
    ["如法泡制", "如法炮制"],
    ["若及若离", "若即若离"],
    ["三步曲", "三部曲"],
    ["骚拢", "骚扰"],
    ["杀风景", "煞风景"],
    ["山青水秀", "山清水秀"],
    ["善长", "擅长"],
    ["瞻养", "赡养"],
    ["申张", "伸张"],
    ["深负众望", "深孚众望"],
    ["神彩", "神采"],
    ["神智不清", "神志不清"],
    ["生杀与夺", "生杀予夺"],
    ["声誉雀起", "声誉鹊起"],
    ["世外桃园", "世外桃源"],
    ["誓不两立", "势不两立"],
    ["手屈一指", "首屈一指"],
    ["授与", "授予"],
    ["书藉", "书籍"],
    ["熟视无赌", "熟视无睹"],
    ["树阴", "树荫"],
    ["水份", "水分"],
    ["说慌", "说谎"],
    ["撕杀", "厮杀"],
    ["耸人听闻", "耸人听闻"],
    ["颂读", "诵读"],
    ["溯流而上", "溯流而上"],
    ["贪脏枉法", "贪赃枉法"],
    ["谈笑风声", "谈笑风生"],
    ["叹为观之", "叹为观止"],
    ["搪塞", "搪塞"],
    ["逃循", "逃遁"],
    ["提练", "提炼"],
    ["天网灰灰", "天网恢恢"],
    ["条分缕拆", "条分缕析"],
    ["挺而走险", "铤而走险"],
    ["通辑", "通缉"],
    ["同仇敌慨", "同仇敌忾"],
    ["投机捣把", "投机倒把"],
    ["突兀森郁", "突兀森郁"],
    ["歪风斜气", "歪风邪气"],
    ["妄费心机", "枉费心机"],
    ["委屈求全", "委曲求全"],
    ["味口", "胃口"],
    ["畏难不前", "畏缩不前"],
    ["闻过饰非", "文过饰非"],
    ["稳操胜卷", "稳操胜券"],
    ["污告", "诬告"],
    ["无精打彩", "无精打采"],
    ["无与论比", "无与伦比"],
    ["物急必反", "物极必反"],
    ["雾蔼", "雾霭"],
    ["息熄相关", "息息相关"],
    ["习以为长", "习以为常"],
    ["喜笑怒骂", "嬉笑怒骂"],
    ["细水常流", "细水长流"],
    ["暇想", "遐想"],
    ["显赫一时", "显赫一时"],
    ["相形见拙", "相形见绌"],
    ["消声匿迹", "销声匿迹"],
    ["协从不问", "胁从不问"],
    ["心安礼得", "心安理得"],
    ["心喜若狂", "欣喜若狂"],
    ["行影不离", "形影不离"],
    ["凶相必露", "凶相毕露"],
    ["修茸", "修葺"],
    ["宣宾夺主", "喧宾夺主"],
    ["寻序渐进", "循序渐进"],
    ["鸦鹊无声", "鸦雀无声"],
    ["淹灭", "湮没"],
    ["言不由中", "言不由衷"],
    ["奄奄一熄", "奄奄一息"],
    ["眼花潦乱", "眼花缭乱"],
    ["一笔勾消", "一笔勾销"],
    ["一愁莫展", "一筹莫展"],
    ["一厥不振", "一蹶不振"],
    ["一股作气", "一鼓作气"],
    ["一如继往", "一如既往"],
    ["一踏糊涂", "一塌糊涂"],
    ["一泄千里", "一泻千里"],
    ["依如往常", "一如往常"],
    ["遗笑大方", "贻笑大方"],
    ["以逸代劳", "以逸待劳"],
    ["义愤填赝", "义愤填膺"],
    ["异曲同功", "异曲同工"],
    ["因地治宜", "因地制宜"],
    ["引亢高歌", "引吭高歌"],
    ["饮鸠止渴", "饮鸩止渴"],
    ["英雄倍出", "英雄辈出"],
    ["忧心重重", "忧心忡忡"],
    ["尤如", "犹如"],
    ["有持无恐", "有恃无恐"],
    ["余勇可估", "余勇可贾"],
    ["鱼舟唱晚", "渔舟唱晚"],
    ["渊远流长", "源远流长"],
    ["原形必露", "原形毕露"],
    ["再接再励", "再接再厉"],
    ["责无旁代", "责无旁贷"],
    ["张慌失措", "张皇失措"],
    ["仗义直言", "仗义执言"],
    ["遮天避日", "遮天蔽日"],
    ["针贬时弊", "针砭时弊"],
    ["震憾", "震撼"],
    ["振耳欲聋", "震耳欲聋"],
    ["直接了当", "直截了当"],
    ["中流抵柱", "中流砥柱"],
    ["众口烁金", "众口铄金"],
    ["专心至志", "专心致志"],
    ["捉襟见胄", "捉襟见肘"],
    ["姿意妄为", "恣意妄为"],
    ["自抱自弃", "自暴自弃"],
    ["走头无路", "走投无路"],
    ["坐收鱼利", "坐收渔利"],
    ["座标", "坐标"],
    ["座落", "坐落"]
];

function fixCommonTypos(text) {
    if (!isEnabled("ruleCommonTypos")) return text;
    var result = text;
    var found = false;
    for (var i = 0; i < commonTypos.length; i++) {
        var from = commonTypos[i][0];
        var to = commonTypos[i][1];
        if (result.indexOf(from) !== -1) {
            result = result.split(from).join(to);
            found = true;
        }
    }
    if (found) inc();
    return result;
}

// ------------------------------------------------------------
// 规则 10: 自定义替换（支持普通替换和正则替换）
//
// 格式（每行一条）:
//   原文→替换              普通文本替换
//   regex:/pattern/→替换   正则表达式替换
//
// 示例:
//   卧槽→我去
//   regex:/第(\d+)章/g→第 $1 回
// ------------------------------------------------------------
function applyCustomReplacements(text) {
    var raw = MoRead.configGet("customReplacements", "");
    if (!raw) return text;

    var lines = raw.split("\n");
    var result = text;
    var found = false;

    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (!line) continue;

        // 找分隔符 → 或 ->
        var arrowIdx = line.indexOf("\u2192");  // →
        var arrowLen = 1;
        if (arrowIdx < 0) {
            arrowIdx = line.indexOf("->");
            arrowLen = 2;
        }
        if (arrowIdx < 0) continue;

        var from = line.substring(0, arrowIdx).trim();
        var to = line.substring(arrowIdx + arrowLen).trim();
        if (!from) continue;

        // 正则模式: regex:/pattern/flags→replacement
        if (from.indexOf("regex:") === 0) {
            var patternStr = from.substring(6);  // 去掉 "regex:"
            // 解析 /pattern/flags
            var lastSlash = patternStr.lastIndexOf("/");
            if (lastSlash > 0 && patternStr.charAt(0) === "/") {
                var pattern = patternStr.substring(1, lastSlash);
                var flags = patternStr.substring(lastSlash + 1);
                try {
                    var re = new RegExp(pattern, flags);
                    if (re.test(result)) {
                        result = result.replace(re, to);
                        found = true;
                    }
                } catch (e) {
                    MoRead.log("正则语法错误: " + pattern + " - " + e.message);
                }
            }
        } else {
            // 普通文本替换
            if (result.indexOf(from) !== -1) {
                result = result.split(from).join(to);
                found = true;
            }
        }
    }

    if (found) inc();
    return result;
}

// ------------------------------------------------------------
// 主处理函数
// ------------------------------------------------------------
function proofread(text) {
    changeCount = 0;
    var result = text;

    // 字符级规范化（先做，避免影响后续规则）
    result = fullwidthNumToHalfwidth(result);
    result = fullwidthLetterToHalfwidth(result);

    // 标点规范化
    result = normalizeQuotes(result);
    result = normalizeEllipsis(result);
    result = halfwidthPunctToFullwidth(result);
    result = collapseRepeatedPunctuation(result);

    // 空白清理
    result = trimWhitespace(result);
    result = collapseNewlines(result);

    // 词汇级修正
    result = fixCommonTypos(result);
    result = applyCustomReplacements(result);

    return result;
}

// ------------------------------------------------------------
// 注册 hook
// ------------------------------------------------------------

// text.display — 显示文本精校
MoRead.hook("text.display", function(params) {
    if (!isEnabled("enableDisplay")) return null;
    var text = params.text || "";
    var result = proofread(text);
    MoRead.log("[Display] 精校完成, 修改约 " + changeCount + " 处");
    return result;
});

// text.preprocess — TTS 朗读文本精校
MoRead.hook("text.preprocess", function(params) {
    if (!isEnabled("enableTTS")) return null;
    var text = params.text || "";
    var result = proofread(text);
    MoRead.log("[TTS] 精校完成, 修改约 " + changeCount + " 处");
    return result;
});

MoRead.log("文本精校模块 v1.1.0 加载完成");
MoRead.log("已注册 hook: text.display, text.preprocess");
