package com.mozhi.reader.modules

import android.content.Context
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.qualifiers.ApplicationContext
import org.json.JSONObject
import java.io.File

/**
 * Scans the modules directory (internal storage) and loads all .js files.
 *
 * Supports:
 * - Master switch (modulesEnabled in config.json)
 * - Per-package enable/disable (packageEnabled map in config.json)
 * - Hot-reload: re-scan and re-evaluate all modules without restarting
 */
@Singleton
class ModuleLoader @Inject constructor(
    @ApplicationContext private val context: Context,
    private val jsEngine: JsEngine,
    private val hookRegistry: HookRegistry
) {
    private val moduleDir: File by lazy {
        File(context.filesDir, "modules").also { it.mkdirs() }
    }

    private val configFile: File by lazy { File(moduleDir, "config.json") }

    private val loadedModules = mutableListOf<String>()

    /**
     * Built-in modules bundled in assets/modules/.
     * These are restored to internal storage on every load,
     * so users cannot permanently delete them.
     */
    private val builtInPackages = listOf("text-proofread", "tts-enhance")

    // ── Built-in module restoration ────────────────────────────────

    /**
     * Copy built-in modules from assets to internal storage.
     * Runs on every loadAll() call so deleted built-in modules are restored.
     */
    private fun restoreBuiltInModules() {
        val assetMgr = context.assets
        for (pkgName in builtInPackages) {
            val targetDir = File(moduleDir, pkgName)
            targetDir.mkdirs()

            try {
                val assetPath = "modules/$pkgName"
                val files = assetMgr.list(assetPath) ?: continue
                for (fileName in files) {
                    val targetFile = File(targetDir, fileName)
                    // Skip if file already exists (preserve user modifications)
                    if (targetFile.exists()) continue
                    try {
                        assetMgr.open("$assetPath/$fileName").use { input ->
                            targetFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        hookRegistry.log("[ModuleLoader] Restored built-in: $pkgName/$fileName")
                    } catch (e: Exception) {
                        hookRegistry.log("[ModuleLoader] Failed to restore $pkgName/$fileName: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                hookRegistry.log("[ModuleLoader] Built-in module $pkgName not found in assets: ${e.message}")
            }
        }
    }

    /**
     * Check if a package name is a built-in module.
     */
    fun isBuiltInPackage(pkgName: String): Boolean = pkgName in builtInPackages

    fun getBuiltInPackages(): List<String> = builtInPackages

    // ── Enable/disable state ───────────────────────────────────────

    fun isModulesEnabled(): Boolean {
        return loadConfig().optBoolean("modulesEnabled", true)
    }

    fun setModulesEnabled(enabled: Boolean) {
        val config = loadConfig()
        config.put("modulesEnabled", enabled)
        saveConfig(config)
    }

    fun isPackageEnabled(packageName: String): Boolean {
        val config = loadConfig()
        val map = config.optJSONObject("packageEnabled")
        return map?.optBoolean(packageName, true) ?: true
    }

    fun setPackageEnabled(packageName: String, enabled: Boolean) {
        val config = loadConfig()
        var map = config.optJSONObject("packageEnabled")
        if (map == null) {
            map = JSONObject()
            config.put("packageEnabled", map)
        }
        map.put(packageName, enabled)
        saveConfig(config)
    }

    private fun loadConfig(): JSONObject {
        return if (configFile.exists()) {
            try { JSONObject(configFile.readText()) } catch (_: Exception) { JSONObject() }
        } else JSONObject()
    }

    private fun saveConfig(config: JSONObject) {
        configFile.writeText(config.toString())
    }

    // ── Loading ───────────────────────────────────────────────────

    @Synchronized
    fun loadAll(): LoadResult {
        // Check master switch
        if (!isModulesEnabled()) {
            jsEngine.restart()
            hookRegistry.clearAll()
            loadedModules.clear()
            hookRegistry.log("[ModuleLoader] Module system disabled by master switch")
            return LoadResult(0, "模块系统已关闭，全部使用原生功能")
        }

        // Restart JS engine to clear all previous state
        jsEngine.restart()

        // Ensure module directory exists
        if (!moduleDir.exists()) {
            moduleDir.mkdirs()
            hookRegistry.log("[ModuleLoader] Module directory created: ${moduleDir.absolutePath}")
        }

        // Restore built-in modules from assets (idempotent: skips existing files)
        restoreBuiltInModules()

        // Scan for .js files in all package subdirectories
        val jsFiles = collectJsFiles(moduleDir)

        if (jsFiles.isEmpty()) {
            hookRegistry.log("[ModuleLoader] No .js modules found in ${moduleDir.absolutePath}")
            return LoadResult(0, "No modules found. Import a .mrm package to get started.")
        }

        loadedModules.clear()
        var successCount = 0
        var skippedCount = 0

        for (file in jsFiles) {
            val moduleName = file.nameWithoutExtension
            val relPath = moduleDir.toURI().relativize(file.toURI()).path
            val fullName = if (relPath.contains("/")) {
                relPath.removeSuffix(".js").replace("/", "/")
            } else {
                moduleName
            }

            // Extract package name from relPath (e.g. "pkg-name/file.js" → "pkg-name")
            val pkgName = if (relPath.contains("/")) {
                relPath.substringBefore("/")
            } else {
                moduleName
            }

            // Check per-package switch
            if (!isPackageEnabled(pkgName)) {
                skippedCount++
                hookRegistry.log("[ModuleLoader] Skipped (disabled): $fullName")
                continue
            }

            ModuleApi.currentModuleName.set(moduleName)

            val success = jsEngine.executeScript(file.absolutePath, fullName)
            if (success) {
                loadedModules.add(fullName)
                successCount++
                hookRegistry.log("[ModuleLoader] Loaded: $fullName ✓")
            } else {
                hookRegistry.log("[ModuleLoader] Failed to load: $fullName ✗")
            }
        }

        ModuleApi.currentModuleName.remove()

        val message = buildString {
            append("Loaded $successCount modules")
            if (skippedCount > 0) append(", $skippedCount disabled")
        }
        hookRegistry.log("[ModuleLoader] $message")
        hookRegistry.log("[ModuleLoader] Registered hooks:\n${hookRegistry.summary()}")

        return LoadResult(successCount, message)
    }

    private fun collectJsFiles(dir: File): List<File> {
        val files = mutableListOf<File>()

        dir.listFiles { _, name -> name.endsWith(".js") }?.let {
            files.addAll(it)
        }

        dir.listFiles { file -> file.isDirectory }?.forEach { pkgDir ->
            pkgDir.listFiles { _, name -> name.endsWith(".js") }?.forEach { jsFile ->
                if (files.none { it.absolutePath == jsFile.absolutePath }) {
                    files.add(jsFile)
                }
            }
        }

        return files.sortedBy { it.absolutePath }
    }

    @Synchronized
    fun reloadModule(moduleName: String): Boolean {
        var file = File(moduleDir, "$moduleName.js")
        if (!file.exists()) {
            moduleDir.listFiles { f -> f.isDirectory }?.forEach { pkgDir ->
                val candidate = File(pkgDir, "$moduleName.js")
                if (candidate.exists()) {
                    file = candidate
                    return@forEach
                }
            }
        }
        if (!file.exists()) return false

        hookRegistry.unregisterModule(moduleName)
        ModuleApi.currentModuleName.set(moduleName)
        val success = jsEngine.executeScript(file.absolutePath, moduleName)
        ModuleApi.currentModuleName.remove()

        if (success && moduleName !in loadedModules) {
            loadedModules.add(moduleName)
        }
        return success
    }

    fun getLoadedModules(): List<String> = loadedModules.toList()

    fun getModuleDir(): String = moduleDir.absolutePath

    fun isReloadRequested(): Boolean = ModuleApi.reloadRequested

    fun clearReloadFlag() { ModuleApi.reloadRequested = false }

    data class LoadResult(
        val loadedCount: Int,
        val message: String
    )
}
