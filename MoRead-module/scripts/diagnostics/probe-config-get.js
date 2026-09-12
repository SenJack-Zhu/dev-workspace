// ============================================================
// 诊断探针模块 (zz-probe)
// 用途：把 MoRead.configGet 的原始返回值写入 storage，供 adb 读取。
// 与 tts-enhance 无关，仅用于排查配置读取问题。
// ============================================================

var KEYS = [
    "enableCustomTTS",
    "enableCustomVoices",
    "enableCustomSegmenter",
    "ttsMode",
    "ttsEndpoint",
    "voicesSource",
    "universalUrlTemplate"
];

var report = {};

// 1) 记录原始 configGet 返回值的类型与内容
for (var i = 0; i < KEYS.length; i++) {
    var k = KEYS[i];
    var raw, typeName, ctorName;
    try {
        raw = MoRead.configGet(k, "false");
        typeName = typeof raw;
        ctorName = (raw && raw.constructor) ? String(raw.constructor.name) : "n/a";
    } catch (e) {
        raw = "ERR:" + e;
        typeName = "error";
        ctorName = "n/a";
    }
    report[k] = {
        value: String(raw),
        jsType: typeName,
        ctor: ctorName,
        isTrueStrict: (raw === "true"),
        isTrueLoose: (raw == "true")
    };
}

// 2) 记录模块自身标识
report["__moduleDir"] = String(MoRead.getModuleDir());
report["__appVersion"] = String(MoRead.getAppVersion());
report["__engine"] = "rhino-es6-interpreter";

// 3) 写入 storage（落盘）
try {
    MoRead.storageSet("probe_report", JSON.stringify(report, null, 2));
    MoRead.log("[PROBE] 诊断报告已写入 storage");
} catch (e) {
    MoRead.log("[PROBE] storageSet 失败: " + e);
}

MoRead.log("[PROBE] " + JSON.stringify(report));
