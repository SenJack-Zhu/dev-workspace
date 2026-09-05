package com.mozhi.reader.modules

/**
 * Static accessor for the hook system, usable from non-Hilt classes
 * (Kotlin object declarations, plain classes, etc.).
 *
 * Initialized once at app startup via [init]. After that, any code path
 * can call [call] or [hasHook] without DI.
 *
 * Hook event naming convention:
 *   - "tts.synthesize"       — override TTS audio synthesis
 *   - "tts.voices"            — override available voice list
 *   - "dialogue.segment"     — override dialogue/narration segmentation
 *   - "role.extract"         — override audiobook role extraction
 *   - "chunk.split"          — override chapter text chunking for vectorization
 *   - "listen.sentence"      — override/transform sentence before playback
 *   - "chapter.beforeRead"   — called before reading a chapter
 *   - "chapter.afterRead"    — called after finishing a chapter
 */
object HookPoints {
    @Volatile
    private var registry: HookRegistry? = null

    /**
     * Wire up the singleton HookRegistry. Called once from Application.onCreate().
     */
    fun init(registry: HookRegistry) {
        this.registry = registry
        registry.log("[HookPoints] Initialized and ready")
    }

    /**
     * Check if any module has registered a hook for [event].
     */
    fun hasHook(event: String): Boolean {
        val r = registry ?: return false
        return r.hasHook(event)
    }

    /**
     * Call hooks for [event] with [params]. Returns the first non-null result,
     * or [default] if no module handled it.
     *
     * Safe to call from any thread. Returns [default] immediately if the
     * hook system is not yet initialized (e.g. during early app startup).
     */
    @Suppress("UNCHECKED_CAST")
    fun <T> call(event: String, params: Map<String, Any?>, default: T): T {
        val r = registry ?: return default
        return r.call(event, params, default)
    }

    /**
     * Convenience overload: call a hook with a simple String result type.
     */
    fun callString(event: String, params: Map<String, Any?>, default: String): String {
        return call(event, params, default)
    }

    /**
     * Convenience overload: call a hook with a Boolean result type.
     */
    fun callBool(event: String, params: Map<String, Any?>, default: Boolean): Boolean {
        return call(event, params, default)
    }

    /**
     * Convenience: call a hook and expect a ByteArray result (e.g. TTS audio bytes).
     */
    fun callBytes(event: String, params: Map<String, Any?>): ByteArray? {
        return callNullable(event, params)
    }

    /**
     * Call a hook that may return null (no module handled it).
     */
    @Suppress("UNCHECKED_CAST")
    fun <T> callNullable(event: String, params: Map<String, Any?>): T? {
        val r = registry ?: return null
        val entries = r.registeredEvents()
        if (event !in entries) return null
        return r.call<T?>(event, params, null)
    }

    /**
     * Get the HookRegistry instance (may be null before init).
     */
    fun registry(): HookRegistry? = registry
}
