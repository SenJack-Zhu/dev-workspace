package com.mozhi.reader.modules

import javax.inject.Inject
import javax.inject.Singleton
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Hook Registry: manages all registered hooks from JS modules.
 *
 * Modules register hooks via MoRead.hook("event.name", function(params) { ... }).
 * Original Kotlin code calls HookRegistry.call() at hook points.
 * If a module returns a non-null result, it overrides the default behavior.
 */
@Singleton
class HookRegistry @Inject constructor() {

    private val hooks = mutableMapOf<String, MutableList<HookEntry>>()
    private val logCollector = mutableListOf<String>()
    private val timeFormat = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.getDefault())

    data class HookEntry(
        val moduleName: String,
        val callback: (Map<String, Any?>) -> Any?
    )

    /**
     * Register a hook for an event.
     * Called from JS: MoRead.hook("tts.synthesize", function(p) { ... })
     */
    @Synchronized
    fun register(event: String, moduleName: String, callback: (Map<String, Any?>) -> Any?) {
        hooks.getOrPut(event) { mutableListOf() }.add(HookEntry(moduleName, callback))
        log("[Module:$moduleName] Registered hook: $event")
    }

    /**
     * Unregister all hooks from a module.
     */
    @Synchronized
    fun unregisterModule(moduleName: String) {
        hooks.values.forEach { list -> list.removeAll { it.moduleName == moduleName } }
        log("[Module:$moduleName] Unregistered all hooks")
    }

    /**
     * Call hooks for an event.
     * Returns the first non-null result from any module, or [default] if no module handled it.
     *
     * @param event Hook event name (e.g. "tts.synthesize")
     * @param params Parameters passed to the hook callback
     * @param default Default value if no module handles the event
     * @return The result from the first module that returns non-null, or [default]
     */
    @Synchronized
    fun <T> call(event: String, params: Map<String, Any?>, default: T): T {
        val entries = hooks[event] ?: return default
        for (entry in entries) {
            try {
                val result = entry.callback(params)
                if (result != null) {
                    @Suppress("UNCHECKED_CAST")
                    return result as T
                }
            } catch (e: Exception) {
                log("[Module:${entry.moduleName}] Hook '$event' error: ${e.message}")
            }
        }
        return default
    }

    /**
     * Check if any module has registered a hook for this event.
     */
    @Synchronized
    fun hasHook(event: String): Boolean = hooks[event]?.isNotEmpty() == true

    /**
     * Get all registered event names.
     */
    @Synchronized
    fun registeredEvents(): Set<String> = hooks.keys.toSet()

    /**
     * Get collected logs.
     */
    fun getLogs(): List<String> = logCollector.toList()

    /**
     * Get all logs as a single text string (for copy/export).
     */
    fun getLogsText(): String = logCollector.joinToString("\n")

    /**
     * Clear all collected logs.
     */
    @Synchronized
    fun clearLogs() {
        logCollector.clear()
        log("[HookRegistry] Logs cleared")
    }

    /**
     * Add a log entry.
     * Logs are automatically pruned to prevent unbounded growth.
     */
    fun log(message: String) {
        val time = timeFormat.format(Date())
        logCollector.add("[$time] $message")
        // Prune: keep last 500 entries
        if (logCollector.size > 500) {
            val removeCount = logCollector.size - 500
            repeat(removeCount) { logCollector.removeAt(0) }
        }
    }

    /**
     * Clear all hooks (for module reload).
     */
    @Synchronized
    fun clearAll() {
        hooks.clear()
        log("[HookRegistry] All hooks cleared")
    }

    /**
     * Get a summary of all registered hooks for debugging.
     */
    @Synchronized
    fun summary(): String {
        if (hooks.isEmpty()) return "No hooks registered"
        return buildString {
            hooks.forEach { (event, entries) ->
                append("  $event (${entries.size} handler(s)):\n")
                entries.forEach { entry ->
                    append("    - ${entry.moduleName}\n")
                }
            }
        }
    }
}
