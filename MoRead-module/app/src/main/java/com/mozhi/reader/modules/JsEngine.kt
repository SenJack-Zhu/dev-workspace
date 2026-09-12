package com.mozhi.reader.modules

import android.content.Context
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.qualifiers.ApplicationContext
import org.mozilla.javascript.Context as RhinoContext
import org.mozilla.javascript.Function
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject

/**
 * JS Engine wrapper using Mozilla Rhino (pure Java, no native dependencies).
 *
 * Provides:
 * - Safe JS execution with interpreter mode (fastest startup, no JIT)
 * - MoRead API object exposed to JS (MoRead.hook, MoRead.http, etc.)
 * - Module loading from filesystem
 */
@Singleton
class JsEngine @Inject constructor(
    @ApplicationContext private val context: Context,
    private val hookRegistry: HookRegistry,
    private val moduleApi: ModuleApi
) {
    private var rhinoContext: RhinoContext? = null
    private var scope: Scriptable? = null

    @Synchronized
    fun initialize() {
        if (rhinoContext != null) return

        rhinoContext = RhinoContext.enter().apply {
            optimizationLevel = -1 // interpreter mode, fastest startup
            languageVersion = RhinoContext.VERSION_ES6
        }
        scope = rhinoContext!!.initStandardObjects()

        // Put the bridge Java object directly into the JS scope.
        // Rhino auto-discovers public methods on Java objects.
        ScriptableObject.putProperty(scope as ScriptableObject, "__bridge", moduleApi)
        moduleApi.setSharedScope(scope!!)

        // Define the MoRead API as a JavaScript wrapper around __bridge.
        // This gives us clean, documented JS signatures without complex
        // Rhino Function bridging.
        // 把宿主返回的 HTTP 结果拆包成纯 JS 值。
        // Rhino 会把 java.lang.String 包装成对象，若不拆包，
        // JS 侧 `typeof body === 'string'`、`b64.length`、字符串比较
        // 全部会失效（尤其影响音频 base64 与二进制嗅探逻辑）。
        val apiDef = """
            function __unwrapHttp(r) {
                if (!r) return null;
                return {
                    status: r.status,
                    ok: r.ok,
                    body: String(r.body === null || r.body === undefined ? '' : r.body),
                    json: (r.json === null || r.json === undefined) ? null : String(r.json),
                    base64: (r.base64 === null || r.base64 === undefined) ? null : String(r.base64),
                    contentType: (r.contentType === null || r.contentType === undefined) ? null : String(r.contentType)
                };
            }

            var MoRead = (function() {
                var b = __bridge;
                return {
                    hook: function(event, callback) { return b.hook(event, callback); },
                    unhook: function() { return b.unhook(); },
                    log: function() {
                        var args = Array.prototype.slice.call(arguments);
                        return b.log.apply(b, args.map(String));
                    },
                    httpGet: function(url, headers) {
                        var h = headers || {};
                        return __unwrapHttp(b.httpGet(url, h));
                    },
                    httpPost: function(url, body, contentType, headers) {
                        var ct = contentType || 'application/json';
                        var h = headers || {};
                        return __unwrapHttp(b.httpPost(url, body || '', ct, h));
                    },
                    httpGetBase64: function(url, headers) {
                        var h = headers || {};
                        var v = b.httpGetBase64(url, h);
                        return (v === null || v === undefined) ? null : String(v);
                    },
                    httpPostBase64: function(url, body, contentType, headers) {
                        var ct = contentType || 'application/json';
                        var h = headers || {};
                        var v = b.httpPostBase64(url, body || '', ct, h);
                        return (v === null || v === undefined) ? null : String(v);
                    },
                    bytesLength: function(b64) {
                        if (!b64) return 0;
                        var s = String(b64);
                        var pad = 0;
                        if (s.charAt(s.length - 1) === '=') pad++;
                        if (s.charAt(s.length - 2) === '=') pad++;
                        return Math.floor(s.length * 3 / 4) - pad;
                    },
                    guessAudioType: function(b64) {
                        if (!b64 || b64.length < 8) return 'audio/mpeg';
                        var head = b64.substring(0, 8);
                        if (head.indexOf('UklGR') === 0) return 'audio/wav';
                        if (head.indexOf('T2dnUw') === 0) return 'audio/ogg';
                        if (head.indexOf('ZkxhQ') === 0) return 'audio/flac';
                        if (head.indexOf('SUQz') === 0) return 'audio/mpeg';
                        if (head.indexOf('//u') === 0 || head.indexOf('//v') === 0) return 'audio/mpeg';
                        return 'audio/mpeg';
                    },
                    // ── 字符串返回值统一用 String() 拆包 ──────────────
                    // Rhino 会把 Kotlin/Java 的 java.lang.String 包装成宿主对象，
                    // 导致 `configGet(k) === "true"` 这类严格比较恒为 false
                    // （typeof 得到 "object" 而非 "string"）。
                    // 在这里统一转成 JS 原生字符串，避免每个模块各自踩坑。
                    configGet: function(key, def) { return String(b.configGet(key, def === undefined || def === null ? '' : String(def))); },
                    configSet: function(key, val) { return b.configSet(key, val === undefined || val === null ? '' : String(val)); },
                    configSave: function() { return b.configSave(); },
                    configReload: function() { return b.configReload(); },
                    storageGet: function(key, def) { return String(b.storageGet(key, def === undefined || def === null ? '' : String(def))); },
                    storageSet: function(key, val) { return b.storageSet(key, val === undefined || val === null ? '' : String(val)); },
                    storageRemove: function(key) { return b.storageRemove(key); },
                    base64Decode: function(str) { return String(b.base64Decode(str || '')); },
                    base64Encode: function(data) { return String(b.base64Encode(data || '')); },
                    pcmToWav: function(b64, sr) { return String(b.pcmToWav(b64 || '', sr || 24000)); },
                    aiChat: function(system, user, role) { return String(b.aiChat(system || '', user || '', role || null)); },
                    aiChatJSON: function(messages, role) { return String(b.aiChatJSON(messages || '[]', role || null)); },
                    aiGenerateImage: function(prompt, count, size) { return b.aiGenerateImage(prompt || '', count || 1, size || null); },
                    aiGenerateImages: function(prompt, count, size) { return b.aiGenerateImages(prompt || '', count || 1, size || null); },
                    getModuleDir: function() { return String(b.moduleDirPath()); },
                    getAppVersion: function() { return String(b.getAppVersion()); },
                    reload: function() { return b.reload(); }
                };
            })();
        """.trimIndent()
        rhinoContext!!.evaluateString(scope, apiDef, "MoReadAPI", 1, null)

        hookRegistry.log("[JsEngine] Initialized with ES6 interpreter mode")
    }

    /**
     * Execute a JS file.
     */
    @Synchronized
    fun executeScript(filePath: String, scriptName: String): Boolean {
        return try {
            initialize()
            val file = java.io.File(filePath)
            if (!file.exists()) {
                hookRegistry.log("[JsEngine] Module file not found: $filePath")
                return false
            }
            val source = file.readText()
            rhinoContext!!.evaluateString(scope, source, scriptName, 1, null)
            true
        } catch (e: Exception) {
            val detail = buildString {
                append(e.message ?: "unknown error")
                // Rhino JavaScriptException 自带行号和源文件信息
                if (e is org.mozilla.javascript.JavaScriptException) {
                    val line = e.lineNumber()
                    val src = e.sourceName()
                    if (line > 0) append(" | line: $line")
                    if (!src.isNullOrBlank()) append(" | source: $src")
                    // 尝试从 details 里拿更多信息
                    val details = e.details
                    if (details != null && details !in e.message.orEmpty()) {
                        append(" | details: $details")
                    }
                }
                // 附加最顶层堆栈，辅助定位
                val stack = e.stackTrace
                if (stack.isNotEmpty()) {
                    append(" | at ${stack[0].fileName}:${stack[0].lineNumber}")
                }
            }
            hookRegistry.log("[JsEngine] Error loading $scriptName: $detail")
            false
        }
    }

    /**
     * Call a function defined in JS.
     */
    @Synchronized
    fun callFunction(functionName: String, vararg args: Any): Any? {
        val fn = ScriptableObject.getProperty(scope as ScriptableObject, functionName) as? Function ?: return null
        return fn.call(rhinoContext, scope, scope, args)
    }

    /**
     * Shutdown and clear context.
     */
    @Synchronized
    fun shutdown() {
        try { RhinoContext.exit() } catch (_: Exception) {}
        rhinoContext = null
        scope = null
    }

    /**
     * Reinitialize (for hot reload).
     */
    @Synchronized
    fun restart() {
        shutdown()
        hookRegistry.clearAll()
        // 清除 ModuleApi 缓存，确保模块重载时读到最新配置
        moduleApi.clearCaches()
        initialize()
    }
}
