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
        /** 单次 HTTP 响应体字节上限，防止异常大响应撑爆堆内存。 */
        const val MAX_RESPONSE_BYTES = 32 * 1024 * 1024

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
     * JS: MoRead.httpGet(url, headers) → { status, body, ok, json?, base64?, contentType? }
     *
     * 文本响应照旧放在 [HttpResult.body]；二进制响应（音频/图片/八位流）改放在
     * [HttpResult.base64]，避免 UTF-8 解码破坏字节。JS 侧用 MoRead.httpGetBase64 取。
     */
    fun httpGet(url: String, headers: java.util.Map<String, String>?): HttpResult? {
        return doHttp("GET", url, null, "application/json", headers)
    }

    /**
     * JS: MoRead.httpPost(url, body, contentType, headers) → { status, body, ok, json?, base64?, contentType? }
     */
    fun httpPost(url: String, body: String, contentType: String, headers: java.util.Map<String, String>?): HttpResult? {
        return doHttp("POST", url, body, contentType, headers)
    }

    /**
     * JS: MoRead.httpGetBase64(url, headers) → base64 字符串或 null
     *
     * 专供 TTS/图片等二进制响应使用。与 [httpGet] 的区别是会强制按字节读取，
     * 无论服务端 Content-Type 是否规范。
     */
    fun httpGetBase64(url: String, headers: java.util.Map<String, String>?): String? {
        return doHttpBinary("GET", url, null, "application/json", headers)
    }

    /**
     * JS: MoRead.httpPostBase64(url, body, contentType, headers) → base64 字符串或 null
     */
    fun httpPostBase64(
        url: String, body: String, contentType: String, headers: java.util.Map<String, String>?
    ): String? {
        return doHttpBinary("POST", url, body, contentType, headers)
    }

    data class HttpResult(
        val status: Int,
        val body: String,
        val ok: Boolean,
        val json: String?,
        /** 二进制响应体的 base64；文本响应时为 null。 */
        val base64: String? = null,
        /** 服务端声明的 Content-Type，便于 JS 推断音频格式。 */
        val contentType: String? = null
    )

    /**
     * 判断响应是否应按二进制处理。
     *
     * 不只看 Content-Type 的 audio/image 前缀：TTS 服务经常把音频标成
     * application/octet-stream，少数还会标成 text/plain 甚至不带 Content-Type。
     * 因此这里同时检查响应体魔数，避免漏判导致音频被文本解码毁掉。
     */
    private fun looksBinary(contentType: String?, head: ByteArray, length: Int): Boolean {
        val ct = contentType?.lowercase()?.substringBefore(';')?.trim().orEmpty()
        if (ct.startsWith("audio/") || ct.startsWith("image/") ||
            ct.startsWith("video/") || ct == "application/octet-stream" ||
            ct == "application/zip" || ct == "application/ogg"
        ) {
            return true
        }
        // Content-Type 不可信时改用魔数判定
        if (length < 4) return false
        fun asciiAt(offset: Int, text: String): Boolean {
            if (offset + text.length > length) return false
            for (i in text.indices) {
                if (head[offset + i] != text[i].code.toByte()) return false
            }
            return true
        }
        return when {
            asciiAt(0, "RIFF") -> true            // WAV / AVI
            asciiAt(0, "OggS") -> true            // Ogg
            asciiAt(0, "fLaC") -> true            // FLAC
            asciiAt(0, "ID3") -> true             // 带 ID3 标签的 MP3
            asciiAt(1, "PNG") && head[0] == 0x89.toByte() -> true
            head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte() -> true   // JPEG
            // MP3 裸帧同步：0xFF 后接 0xE0 掩码
            head[0] == 0xFF.toByte() && (head[1].toInt() and 0xE0) == 0xE0 -> true
            else -> false
        }
    }

    /** 读取响应流，超过 [MAX_RESPONSE_BYTES] 时截断并记录日志。 */
    private fun readStreamLimited(stream: java.io.InputStream): ByteArray {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        var total = 0
        var truncated = false
        while (total < MAX_RESPONSE_BYTES) {
            val capacity = MAX_RESPONSE_BYTES - total
            val read = stream.read(chunk, 0, if (capacity < chunk.size) capacity else chunk.size)
            if (read <= 0) break
            buffer.write(chunk, 0, read)
            total += read
        }
        // 达到上限后判断是否还有剩余数据
        if (total >= MAX_RESPONSE_BYTES && stream.read() >= 0) truncated = true
        if (truncated) {
            hookRegistry.log(
                "[HTTP] Response exceeds ${MAX_RESPONSE_BYTES / 1024 / 1024} MB, truncated"
            )
        }
        return buffer.toByteArray()
    }

    private fun openConnection(
        method: String, url: String, body: String?, contentType: String,
        headers: java.util.Map<String, String>?
    ): java.net.HttpURLConnection {
        return (java.net.URL(url).openConnection() as java.net.HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 30000
            readTimeout = 60000
            if (method == "POST") {
                setRequestProperty("Content-Type", contentType)
                doOutput = true
                // 注意：部分自建 TTS 服务只要收到请求体就会直接断开连接，
                // 因此仅在确实有 body 时才写入。
                if (!body.isNullOrEmpty()) {
                    outputStream.use { it.write(body.toByteArray()) }
                }
            }
            headers?.forEach { k, v -> setRequestProperty(k, v) }
        }
    }

    private fun doHttp(
        method: String, url: String, body: String?, contentType: String,
        headers: java.util.Map<String, String>?
    ): HttpResult? {
        return try {
            val conn = openConnection(method, url, body, contentType, headers)
            val code = conn.responseCode
            val ct = conn.getHeaderField("Content-Type")
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            if (stream == null) {
                return HttpResult(code, "", code in 200..299, null, null, ct)
            }
            val bytes = stream.use { readStreamLimited(it) }

            if (looksBinary(ct, bytes, bytes.size)) {
                // 二进制：不做文本解码，交给 base64
                val b64 = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
                hookRegistry.log("[HTTP] $method 二进制响应 ${bytes.size} 字节 (${ct ?: "无 Content-Type"})")
                HttpResult(code, "", code in 200..299, null, b64, ct)
            } else {
                val respBody = String(bytes, Charsets.UTF_8)
                val jsonStr = try { JSONObject(respBody).toString() } catch (_: Exception) { null }
                HttpResult(code, respBody, code in 200..299, jsonStr, null, ct)
            }
        } catch (e: Exception) {
            hookRegistry.log("[HTTP] $method $url error: ${e.message}")
            null
        }
    }

    /**
     * 强制按二进制读取（调用方明确知道要的是音频/图片）。
     */
    private fun doHttpBinary(
        method: String, url: String, body: String?, contentType: String,
        headers: java.util.Map<String, String>?
    ): String? {
        return try {
            val conn = openConnection(method, url, body, contentType, headers)
            val code = conn.responseCode
            if (code !in 200..299) {
                hookRegistry.log("[HTTP] $method $url 失败: HTTP $code")
                return null
            }
            val bytes = (conn.inputStream ?: return null).use { readStreamLimited(it) }
            if (bytes.isEmpty()) {
                hookRegistry.log("[HTTP] $method $url 返回空响应体")
                return null
            }
            android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
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
     * 
     * 改进：支持多种布尔值格式的自动转换和类型兼容性。
     * 处理场景：
     * - JSON 中布尔值被保存为 true/false（Boolean）
     * - JSON 中数字被保存为 0/1（Number）
     * - UI 层可能用不同的格式保存值
     */
    fun configGet(key: String, default: String, packageName: String?): String {
        loadConfig()
        val prefixed = prefixedKeyWith(key, packageName)
        val cache = configCache ?: return default
        
        // 优先用带前缀的 key
        if (cache.has(prefixed)) {
            val value = cache.opt(prefixed)
            return normalizeConfigValue(value, default)
        }
        
        // 向后兼容：尝试不带前缀的旧 key
        if (prefixed != key && cache.has(key)) {
            val value = cache.opt(key)
            return normalizeConfigValue(value, default)
        }
        
        return default
    }

    /**
     * 规范化配置值，处理不同的类型和格式。
     * 
     * 转换规则：
     * - String: 直接返回
     * - Boolean: true → "true", false → "false"
     * - Number: 0 → "false", 非0 → "true"
     * - 其他对象: 调用 toString() 并规范化
     * 
     * 这解决了 UI 层保存配置时可能出现的类型不匹配问题。
     */
    private fun normalizeConfigValue(value: Any?, default: String): String {
        if (value == null) return default
        
        return when (value) {
            is String -> {
                // 直接是字符串，返回原值
                value
            }
            is Boolean -> {
                // 布尔值转成字符串 "true" 或 "false"
                if (value) "true" else "false"
            }
            is Number -> {
                // 数字：0 → "false"，其他 → "true"
                if (value.toInt() == 0) "false" else "true"
            }
            else -> {
                // 其他类型，转字符串后规范化
                val str = value.toString().trim().lowercase()
                when {
                    str in listOf("true", "yes", "1", "on") -> "true"
                    str in listOf("false", "no", "0", "off", "") -> "false"
                    else -> value.toString()
                }
            }
        }
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
