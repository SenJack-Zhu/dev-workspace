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
        val apiDef = """
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
                        var r = b.httpGet(url, h);
                        return r ? { status: r.status, body: r.body, ok: r.ok, json: r.json } : null;
                    },
                    httpPost: function(url, body, contentType, headers) {
                        var ct = contentType || 'application/json';
                        var h = headers || {};
                        var r = b.httpPost(url, body || '', ct, h);
                        return r ? { status: r.status, body: r.body, ok: r.ok, json: r.json } : null;
                    },
                    configGet: function(key, def) { return b.configGet(key, def || ''); },
                    configSet: function(key, val) { return b.configSet(key, val); },
                    configSave: function() { return b.configSave(); },
                    configReload: function() { return b.configReload(); },
                    storageGet: function(key, def) { return b.storageGet(key, def || ''); },
                    storageSet: function(key, val) { return b.storageSet(key, val); },
                    storageRemove: function(key) { return b.storageRemove(key); },
                    base64Decode: function(str) { return b.base64Decode(str); },
                    base64Encode: function(data) { return b.base64Encode(data); },
                    pcmToWav: function(b64, sr) { return b.pcmToWav(b64, sr || 24000); },
                    getModuleDir: function() { return b.moduleDirPath(); },
                    getAppVersion: function() { return b.getAppVersion(); },
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
            hookRegistry.log("[JsEngine] Error loading $scriptName: ${e.message}")
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
        initialize()
    }
}
