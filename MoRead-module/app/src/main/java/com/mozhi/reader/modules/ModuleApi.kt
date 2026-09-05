package com.mozhi.reader.modules

import android.content.Context
import android.content.pm.PackageManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import org.json.JSONObject
import org.mozilla.javascript.Context as RhinoContext
import org.mozilla.javascript.Function
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject

/**
 * Bridge between JS modules and MoRead's Kotlin internals.
 *
 * Each method has simple Java-friendly signatures so Rhino can auto-dispatch
 * from JavaScript calls. The MoRead API object is defined in JS as a thin
 * wrapper that delegates to __bridge (this object).
 */
@Singleton
class ModuleApi @Inject constructor(
    @ApplicationContext private val context: Context,
    private val hookRegistry: HookRegistry
) {
    companion object {
        val currentModuleName = ThreadLocal<String>()
        @Volatile var reloadRequested = false

        fun pcmToWavBytes(pcm: ByteArray, sampleRate: Int, channels: Int, bitsPerSample: Int): ByteArray {
            val byteRate = sampleRate * channels * bitsPerSample / 8
            val blockAlign = channels * bitsPerSample / 8
            val dataSize = pcm.size
            val bufferSize = 44 + dataSize
            val buffer = java.nio.ByteBuffer.allocate(bufferSize)
            buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
            buffer.put("RIFF".toByteArray())
            buffer.putInt(bufferSize - 8)
            buffer.put("WAVE".toByteArray())
            buffer.put("fmt ".toByteArray())
            buffer.putInt(16)
            buffer.putShort(1)
            buffer.putShort(channels.toShort())
            buffer.putInt(sampleRate)
            buffer.putInt(byteRate)
            buffer.putShort(blockAlign.toShort())
            buffer.putShort(bitsPerSample.toShort())
            buffer.put("data".toByteArray())
            buffer.putInt(dataSize)
            buffer.put(pcm)
            return buffer.array()
        }
    }

    private val moduleDir: String by lazy {
        java.io.File(context.filesDir, "modules").also { it.mkdirs() }.absolutePath
    }

    private val configFile: java.io.File by lazy { java.io.File(moduleDir, "config.json") }
    private var configCache: JSONObject? = null

    private val storageFile: java.io.File by lazy { java.io.File(moduleDir, "storage.json") }
    private var storageCache: JSONObject? = null

    // Track scope for async callback invocation
    @Volatile private var sharedScope: Scriptable? = null

    fun setSharedScope(scope: Scriptable) {
        sharedScope = scope
    }

    // ── Hook registration ──────────────────────────────────────────

    /**
     * JS: MoRead.hook("event.name", function(params) { ... })
     */
    fun hook(event: String, callback: Function) {
        val moduleName = currentModuleName.get() ?: "unknown"
        val scope = sharedScope
        if (scope == null) {
            hookRegistry.log("[Module:$moduleName] Cannot register hook: JS scope not ready")
            return
        }
        val wrapped = { params: Map<String, Any?> ->
            try {
                val cx = RhinoContext.enter()
                try {
                    val jsParams = cx.newObject(scope)
                    params.forEach { (k, v) ->
                        ScriptableObject.putProperty(jsParams, k, v)
                    }
                    callback.call(cx, scope, scope, arrayOf(jsParams))
                } finally {
                    RhinoContext.exit()
                }
            } catch (e: Exception) {
                hookRegistry.log("[Module:$moduleName] Hook '$event' callback error: ${e.message}")
                null
            }
        }
        hookRegistry.register(event, moduleName, wrapped)
    }

    /**
     * JS: MoRead.unhook()  — unregister all hooks from the current module.
     */
    fun unhook() {
        val moduleName = currentModuleName.get() ?: "unknown"
        hookRegistry.unregisterModule(moduleName)
    }

    // ── Logging ────────────────────────────────────────────────────

    /**
     * JS: MoRead.log("message")
     */
    fun log(vararg args: String) {
        val message = args.joinToString(" ")
        val moduleName = currentModuleName.get() ?: "unknown"
        hookRegistry.log("[Module:$moduleName] $message")
    }

    // ── HTTP client (synchronous) ──────────────────────────────────

    /**
     * JS: MoRead.httpGet(url, headers) → { status, body, ok, json? }
     */
    fun httpGet(url: String, headers: java.util.Map<String, String>?): HttpResult? {
        return doHttp("GET", url, null, "application/json", headers)
    }

    /**
     * JS: MoRead.httpPost(url, body, contentType, headers) → { status, body, ok, json? }
     */
    fun httpPost(url: String, body: String, contentType: String, headers: java.util.Map<String, String>?): HttpResult? {
        return doHttp("POST", url, body, contentType, headers)
    }

    data class HttpResult(val status: Int, val body: String, val ok: Boolean, val json: String?)

    private fun doHttp(
        method: String, url: String, body: String?, contentType: String,
        headers: java.util.Map<String, String>?
    ): HttpResult? {
        return try {
            val conn = (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 30000
                readTimeout = 60000
                if (method == "POST") {
                    setRequestProperty("Content-Type", contentType)
                    doOutput = true
                    if (body != null) {
                        outputStream.use { it.write(body.toByteArray()) }
                    }
                }
                headers?.forEach { k, v -> setRequestProperty(k, v) }
            }
            val code = conn.responseCode
            val respBody = if (code in 200..299) {
                conn.inputStream.bufferedReader().use { it.readText() }
            } else {
                conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
            }
            val jsonStr = try { JSONObject(respBody).toString() } catch (_: Exception) { null }
            HttpResult(code, respBody, code in 200..299, jsonStr)
        } catch (e: Exception) {
            hookRegistry.log("[HTTP] $method $url error: ${e.message}")
            null
        }
    }

    // ── Config (shared JSON in modules/config.json) ────────────────

    fun configGet(key: String, default: String): String {
        loadConfig()
        return configCache?.optString(key, default) ?: default
    }

    fun configSet(key: String, value: String) {
        loadConfig()
        configCache?.put(key, value)
    }

    fun configSave() {
        saveConfig()
    }

    fun configReload() {
        configCache = null
        loadConfig()
    }

    // ── Storage (persistent per-module key-value) ──────────────────

    fun storageGet(key: String, default: String): String {
        loadStorage()
        return storageCache?.optString(key, default) ?: default
    }

    fun storageSet(key: String, value: String) {
        loadStorage()
        storageCache?.put(key, value)
        saveStorage()
    }

    fun storageRemove(key: String) {
        loadStorage()
        storageCache?.remove(key)
        saveStorage()
    }

    // ── Audio utilities ────────────────────────────────────────────

    fun base64Decode(str: String): ByteArray? {
        return try {
            android.util.Base64.decode(str, android.util.Base64.DEFAULT)
        } catch (e: Exception) { null }
    }

    fun base64Encode(data: Any): String? {
        return when (data) {
            is ByteArray -> android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)
            is String -> android.util.Base64.encodeToString(data.toByteArray(), android.util.Base64.NO_WRAP)
            else -> null
        }
    }

    /**
     * Convert raw PCM (base64 encoded) to WAV format (base64 encoded).
     */
    fun pcmToWav(pcmBase64: String, sampleRate: Int): String? {
        return try {
            val pcm = android.util.Base64.decode(pcmBase64, android.util.Base64.DEFAULT)
            val wav = pcmToWavBytes(pcm, sampleRate, 1, 16)
            android.util.Base64.encodeToString(wav, android.util.Base64.NO_WRAP)
        } catch (e: Exception) {
            hookRegistry.log("[Audio] pcmToWav error: ${e.message}")
            null
        }
    }

    // ── Misc ───────────────────────────────────────────────────────

    fun moduleDirPath(): String = moduleDir

    fun getAppVersion(): String {
        return try {
            val pInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            pInfo.versionName ?: "unknown"
        } catch (e: PackageManager.NameNotFoundException) {
            "unknown"
        }
    }

    fun reload() {
        reloadRequested = true
    }

    // ── Internal helpers ───────────────────────────────────────────

    private fun loadConfig() {
        if (configCache != null) return
        configCache = try {
            if (configFile.exists()) JSONObject(configFile.readText())
            else JSONObject()
        } catch (e: Exception) {
            hookRegistry.log("[Config] Load error: ${e.message}")
            JSONObject()
        }
    }

    private fun saveConfig() {
        try {
            configFile.writeText(configCache?.toString(2) ?: "{}")
            hookRegistry.log("[Config] Saved to ${configFile.absolutePath}")
        } catch (e: Exception) {
            hookRegistry.log("[Config] Save error: ${e.message}")
        }
    }

    private fun loadStorage() {
        if (storageCache != null) return
        storageCache = try {
            if (storageFile.exists()) JSONObject(storageFile.readText())
            else JSONObject()
        } catch (e: Exception) { JSONObject() }
    }

    private fun saveStorage() {
        try {
            storageFile.writeText(storageCache?.toString(2) ?: "{}")
        } catch (e: Exception) {
            hookRegistry.log("[Storage] Save error: ${e.message}")
        }
    }
}
