package com.mozhi.reader.modules

import android.content.Context
import javax.inject.Inject
import javax.inject.Singleton
import java.io.File

/**
 * Scans the modules directory (internal storage) and loads all .js files.
 *
 * Directory structure:
 * ```
 * context.filesDir/modules/
 *   ├── config.json           (shared config, merged from all packages)
 *   ├── storage.json          (shared persistent storage)
 *   ├── <package-name>/
 *   │   ├── manifest.json     (package metadata)
 *   │   ├── *.js              (JavaScript module files)
 *   │   └── config.json      (package-specific config, merged at import time)
 *   └── <package-name>/
 *       ├── manifest.json
 *       └── *.js
 * ```
 *
 * Modules are loaded from all package subdirectories, sorted by package name
 * then file name. This ensures deterministic loading order across reloads.
 *
 * Also supports hot-reload: re-scan, re-evaluate all modules without restarting the app.
 */
@Singleton
class ModuleLoader @Inject constructor(
    private val context: Context,
    private val jsEngine: JsEngine,
    private val hookRegistry: HookRegistry
) {
    /** Root modules directory in internal storage. */
    private val moduleDir: File by lazy {
        File(context.filesDir, "modules").also { it.mkdirs() }
    }

    private val loadedModules = mutableListOf<String>()

    /**
     * Load all .js modules from all package subdirectories.
     * Called at app startup or when user triggers "Reload Modules".
     */
    @Synchronized
    fun loadAll(): LoadResult {
        // Restart JS engine to clear all previous state
        jsEngine.restart()

        if (!moduleDir.exists()) {
            moduleDir.mkdirs()
            hookRegistry.log("[ModuleLoader] Module directory created: ${moduleDir.absolutePath}")
            return LoadResult(0, "Module directory created in internal storage")
        }

        // Scan for .js files in the root and all subdirectories
        val jsFiles = collectJsFiles(moduleDir)

        if (jsFiles.isEmpty()) {
            hookRegistry.log("[ModuleLoader] No .js modules found in ${moduleDir.absolutePath}")
            return LoadResult(0, "No modules found. Import a .mrm package to get started.")
        }

        loadedModules.clear()
        var successCount = 0

        for (file in jsFiles) {
            val moduleName = file.nameWithoutExtension
            // Include package name to disambiguate modules with same filename
            val relPath = moduleDir.toURI().relativize(file.toURI()).path
            val fullName = if (relPath.contains("/")) {
                relPath.removeSuffix(".js").replace("/", "/")
            } else {
                moduleName
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

        val message = "Loaded $successCount/${jsFiles.size} modules"
        hookRegistry.log("[ModuleLoader] $message")
        hookRegistry.log("[ModuleLoader] Registered hooks:\n${hookRegistry.summary()}")

        return LoadResult(successCount, message)
    }

    /**
     * Collect all .js files from the root directory and all subdirectories,
     * sorted by relative path for deterministic loading order.
     */
    private fun collectJsFiles(dir: File): List<File> {
        val files = mutableListOf<File>()

        // Direct .js files in the root (legacy support)
        dir.listFiles { _, name -> name.endsWith(".js") }?.let {
            files.addAll(it)
        }

        // .js files in subdirectories (each subdirectory = one package)
        dir.listFiles { file -> file.isDirectory }?.forEach { pkgDir ->
            pkgDir.listFiles { _, name -> name.endsWith(".js") }?.forEach { jsFile ->
                // Only add if not already in the list (avoid duplicates)
                if (files.none { it.absolutePath == jsFile.absolutePath }) {
                    files.add(jsFile)
                }
            }
        }

        return files.sortedBy { it.absolutePath }
    }

    /**
     * Reload a single module by name (or relative path).
     */
    @Synchronized
    fun reloadModule(moduleName: String): Boolean {
        // Try direct file first
        var file = File(moduleDir, "$moduleName.js")
        if (!file.exists()) {
            // Try in subdirectories
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

    /**
     * Get list of loaded module names.
     */
    fun getLoadedModules(): List<String> = loadedModules.toList()

    /**
     * Get the module directory path (internal storage).
     */
    fun getModuleDir(): String = moduleDir.absolutePath

    /**
     * Check if a reload was requested by a module (via MoRead.reload()).
     */
    fun isReloadRequested(): Boolean = ModuleApi.reloadRequested

    /**
     * Clear reload flag.
     */
    fun clearReloadFlag() { ModuleApi.reloadRequested = false }

    data class LoadResult(
        val loadedCount: Int,
        val message: String
    )
}
