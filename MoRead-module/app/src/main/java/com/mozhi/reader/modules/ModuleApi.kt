package com.mozhi.reader.modules

import android.content.Context
import android.content.pm.PackageManager
import com.mozhi.reader.ai.client.AiClientFactory
import com.mozhi.reader.ai.client.ChatMessage
import com.mozhi.reader.ai.client.ChatRole
import com.mozhi.reader.core.database.entity.ModelRole
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.runBlocking
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
    private val hookRegistry: HookRegistry,
    private val aiClientFactory: AiClientFactory
) {
    companion object {
        val currentModuleName = ThreadLocal<String>()
        val currentPackageName = ThreadLocal<String>()
        @Volatile var reloadRequested = false

        /**
         * 给 key 加上包名前缀，实现模块间配置隔离。
         * 格式："<packageName>:<key>"
         * 如果没有当前包名（系统调用），返回原始 key。
         */
        fun prefixedKey(key: String): String {
            val pkg = currentPackageName.get()
            return if (pkg.isNullOrBlank()) key else "$pkg:$key"
        }

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

    // ── AI chat (reuses native AI providers) ──────────────────────

    /**
     * JS: MoRead.aiChat(systemPrompt, userMessage, role) → String?
     *
     * 调用原生配置好的 AI 供应商，复用所有 API Key、模型设置。
     * role: "CHEAP"（默认）/ "SMART" / "CHAT" / "SUGGESTION"
     * 返回 AI 回复文本，失败返回 null。
     */
    fun aiChat(systemPrompt: String, userMessage: String, role: String?): String? {
        val modelRole = try {
            ModelRole.valueOf(role?.uppercase() ?: "CHEAP")
        } catch (_: Exception) {
            ModelRole.CHEAP
        }
        return try {
            runBlocking {
                val resolved = aiClientFactory.forRole(modelRole)
                val messages = listOf(
                    ChatMessage(ChatRole.SYSTEM, systemPrompt),
                    ChatMessage(ChatRole.USER, userMessage)
                )
                resolved.client.chat(messages, resolved.options)
            }
        } catch (e: Exception) {
            val moduleName = currentModuleName.get() ?: "unknown"
            hookRegistry.log("[Module:$moduleName] aiChat error: ${e.message}")
            null
        }
    }

    /**
     * JS: MoRead.aiChatJSON(messagesJSON, role) → String?
     *
     * 支持多轮对话的版本，messagesJSON 是 JSON 数组：
     * [{"role":"system","content":"..."},{"role":"user","content":"..."}]
     * role 同上。
     */
    fun aiChatJSON(messagesJSON: String, role: String?): String? {
        val modelRole = try {
            ModelRole.valueOf(role?.uppercase() ?: "CHEAP")
        } catch (_: Exception) {
            ModelRole.CHEAP
        }
        return try {
            val arr = org.json.JSONArray(messagesJSON)
            val messages = mutableListOf<ChatMessage>()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val roleStr = obj.optString("role", "user").uppercase()
                val content = obj.optString("content", "")
                val chatRole = when (roleStr) {
                    "SYSTEM" -> ChatRole.SYSTEM
                    "ASSISTANT" -> ChatRole.ASSISTANT
                    "TOOL" -> ChatRole.TOOL
                    else -> ChatRole.USER
                }
                messages.add(ChatMessage(chatRole, content))
            }
            runBlocking {
                val resolved = aiClientFactory.forRole(modelRole)
                resolved.client.chat(messages, resolved.options)
            }
        } catch (e: Exception) {
            val moduleName = currentModuleName.get() ?: "unknown"
            hookRegistry.log("[Module:$moduleName] aiChatJSON error: ${e.message}")
            null
        }
    }

    // ── Image generation (reuses native image providers) ──────────

    /**
     * JS: MoRead.aiGenerateImage(prompt, count, size) → String?
     *
     * 调用原生配置好的生图服务，返回第一张图的 base64（PNG/JPEG）。
     * prompt：提示词（中文/英文均可，会自动转换为对应格式）
     * count：生成数量（默认 1）
     * size：尺寸，如 "1024x1024"（空则用默认）
     * 返回 base64 字符串，失败返回 null。
     */
    fun aiGenerateImage(prompt: String, count: Int, size: String?): String? {
        return try {
            runBlocking {
                val resolved = aiClientFactory.imageGeneration()
                val images = resolved.client.generateImages(
                    prompt = prompt,
                    count = count.coerceAtLeast(1),
                    size = size?.takeIf { it.isNotBlank() }
                )
                // 取第一张图，优先 bytes，否则 materialize
                val first = images.firstOrNull() ?: return@runBlocking null
                val bytes = first.bytes ?: resolved.client.materializeImage(first)
                android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
            }
        } catch (e: Exception) {
            val moduleName = currentModuleName.get() ?: "unknown"
            hookRegistry.log("[Module:$moduleName] aiGenerateImage error: ${e.message}")
            null
        }
    }

    /**
     * JS: MoRead.aiGenerateImages(prompt, count, size) → String? (JSON array of base64)
     *
     * 生成多张图，返回 JSON 数组 ["base64_1", "base64_2", ...]
     */
    fun aiGenerateImages(prompt: String, count: Int, size: String?): String? {
        return try {
            runBlocking {
                val resolved = aiClientFactory.imageGeneration()
                val images = resolved.client.generateImages(
                    prompt = prompt,
                    count = count.coerceAtLeast(1),
                    size = size?.takeIf { it.isNotBlank() }
                )
                val base64List = images.map { img ->
                    val bytes = img.bytes ?: resolved.client.materializeImage(img)
                    android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                }
                org.json.JSONArray(base64List).toString()
            }
        } catch (e: Exception) {
            val moduleName = currentModuleName.get() ?: "unknown"
            hookRegistry.log("[Module:$moduleName] aiGenerateImages error: ${e.message}")
            null
        }
    }

    // ── Config (shared JSON in modules/config.json) ────────────────

    /**
     * 读取配置值。key 会自动加上包名前缀实现隔离。
     * 向后兼容：如果带前缀的 key 找不到，会尝试查找不带前缀的旧 key。
     * @param key 配置项 key（不带前缀）
     * @param default 默认值
     */
    fun configGet(key: String, default: String): String {
        return configGet(key, default, null)
    }

    /**
     * 读取配置值（带显式包名，供 Kotlin 侧调用）。
     */
    fun configGet(key: String, default: String, packageName: String?): String {
        loadConfig()
        val prefixed = prefixedKeyWith(key, packageName)
        val cache = configCache ?: return default
        // 优先用带前缀的 key
        if (cache.has(prefixed)) {
            return cache.optString(prefixed, default)
        }
        // 向后兼容：尝试不带前缀的旧 key
        if (prefixed != key && cache.has(key)) {
            return cache.optString(key, default)
        }
        return default
    }

    /**
     * 写入配置值。key 会自动加上包名前缀实现隔离。
     * @param key 配置项 key（不带前缀）
     * @param value 值
     */
    fun configSet(key: String, value: String) {
        configSet(key, value, null)
    }

    /**
     * 写入配置值（带显式包名，供 Kotlin 侧调用）。
     */
    fun configSet(key: String, value: String, packageName: String?) {
        loadConfig()
        val prefixed = prefixedKeyWith(key, packageName)
        configCache?.put(prefixed, value)
        saveConfig()
    }

    private fun prefixedKeyWith(key: String, explicitPackage: String?): String {
        val pkg = explicitPackage ?: currentPackageName.get()
        return if (pkg.isNullOrBlank()) key else "$pkg:$key"
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
        return storageGet(key, default, null)
    }

    fun storageGet(key: String, default: String, packageName: String?): String {
        loadStorage()
        val prefixed = prefixedKeyWith(key, packageName)
        val cache = storageCache ?: return default
        if (cache.has(prefixed)) {
            return cache.optString(prefixed, default)
        }
        // 向后兼容：尝试不带前缀的旧 key
        if (prefixed != key && cache.has(key)) {
            return cache.optString(key, default)
        }
        return default
    }

    fun storageSet(key: String, value: String) {
        storageSet(key, value, null)
    }

    fun storageSet(key: String, value: String, packageName: String?) {
        loadStorage()
        val prefixed = prefixedKeyWith(key, packageName)
        storageCache?.put(prefixed, value)
        saveStorage()
    }

    fun storageRemove(key: String) {
        storageRemove(key, null)
    }

    fun storageRemove(key: String, packageName: String?) {
        loadStorage()
        val prefixed = prefixedKeyWith(key, packageName)
        storageCache?.remove(prefixed)
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

    /**
     * 清除 config 和 storage 缓存（模块重载前调用）。
     */
    fun clearCaches() {
        configCache = null
        storageCache = null
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
