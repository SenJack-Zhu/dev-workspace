package com.mozhi.reader.modules

import android.content.Context
import android.net.Uri
import javax.inject.Inject
import javax.inject.Singleton
import dagger.hilt.android.qualifiers.ApplicationContext
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Result of a module package import operation.
 */
data class ImportResult(
    val success: Boolean,
    val packageName: String,
    val displayName: String,
    val version: String,
    val jsFileCount: Int,
    val message: String
)

/**
 * Imports .mrm (MoRead Module) archive files into the app's internal storage.
 *
 * A .mrm file is a standard ZIP archive. The importer:
 * 1. Reads the archive from a content URI (file picker) or file path
 * 2. Parses manifest.json for package metadata (optional)
 * 3. Extracts all files to [moduleDir]/<packageName>/
 * 4. Merges package config.json into the shared config
 *
 * The modules directory is in **internal storage** (context.filesDir),
 * which means:
 * - Root users can directly edit module files via a root file manager
 * - Non-root users modify files, repackage as .mrm, and re-import
 * - Files are protected from accidental deletion by file managers
 */
@Singleton
class ModuleImporter @Inject constructor(
    @ApplicationContext private val context: Context,
    private val hookRegistry: HookRegistry,
    private val moduleApi: ModuleApi
) {
    companion object {
        private const val MODULES_DIR = "modules"
        private const val MANIFEST_FILE = "manifest.json"
        private const val CONFIG_FILE = "config.json"
        private const val MAX_PACKAGE_SIZE = 50 * 1024 * 1024L // 50 MB
    }

    /** Root modules directory in internal storage. */
    val moduleDir: File by lazy {
        File(context.filesDir, MODULES_DIR).also { it.mkdirs() }
    }

    /**
     * Import a .mrm package from a content URI (e.g. from SAF file picker).
     */
    suspend fun importFromUri(uri: Uri): ImportResult {
        return try {
            val tempFile = File(context.cacheDir, "mrm_import_${System.currentTimeMillis()}.zip")
            context.contentResolver.openInputStream(uri)?.use { input ->
                tempFile.outputStream().use { output -> input.copyTo(output) }
            } ?: return ImportResult(false, "", "", "", 0, "Cannot open file")

            val result = importFromZipFile(tempFile)
            tempFile.delete()
            result
        } catch (e: Exception) {
            ImportResult(false, "", "", "", 0, "Import failed: ${e.message}")
        }
    }

    /**
     * Import a .mrm package from a local file path.
     */
    suspend fun importFromPath(filePath: String): ImportResult {
        val file = File(filePath)
        if (!file.exists()) {
            return ImportResult(false, "", "", "", 0, "File not found: $filePath")
        }
        return importFromZipFile(file)
    }

    /**
     * Import a .mrm package from an input stream (e.g. from intent extras).
     */
    suspend fun importFromStream(input: InputStream, fallbackName: String): ImportResult {
        return try {
            val tempFile = File(context.cacheDir, "mrm_import_${System.currentTimeMillis()}.zip")
            tempFile.outputStream().use { output -> input.copyTo(output) }
            val result = importFromZipFile(tempFile, fallbackName)
            tempFile.delete()
            result
        } catch (e: Exception) {
            ImportResult(false, "", "", "", 0, "Import failed: ${e.message}")
        }
    }

    /**
     * Core import logic: unzip, parse manifest, extract to package directory.
     */
    private suspend fun importFromZipFile(zipFile: File, fallbackName: String = ""): ImportResult {
        if (zipFile.length() > MAX_PACKAGE_SIZE) {
            return ImportResult(false, "", "", "", 0, "Package too large (max 50 MB)")
        }

        var packageName = ""
        var displayName = ""
        var version = "1.0.0"
        var manifest: JSONObject? = null
        var packageConfig: JSONObject? = null
        val extractedFiles = mutableListOf<String>()
        val jsFiles = mutableListOf<String>()

        try {
            ZipInputStream(zipFile.inputStream(), Charsets.UTF_8).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val entryName = entry.name

                    // Skip directory entries
                    if (entryName.endsWith("/")) {
                        entry = zis.nextEntry
                        continue
                    }

                    // Skip potentially dangerous paths
                    if (entryName.contains("..") || entryName.startsWith("/")) {
                        hookRegistry.log("[Importer] Skipping unsafe path: $entryName")
                        entry = zis.nextEntry
                        continue
                    }

                    // Read manifest.json — use readBytes() not bufferedReader()
                    // BufferedReader has 8KB buffer that can read into next entry
                    if (entryName == MANIFEST_FILE || entryName.endsWith("/$MANIFEST_FILE")) {
                        val bytes = zis.readBytes()
                        val content = String(bytes, Charsets.UTF_8)
                        manifest = JSONObject(content)
                        packageName = manifest.optString("name", "")
                        displayName = manifest.optString("displayName", packageName)
                        version = manifest.optString("version", "1.0.0")
                        entry = zis.nextEntry
                        continue
                    }

                    // Read package config.json (for merging)
                    if (entryName == CONFIG_FILE || entryName.endsWith("/$CONFIG_FILE")) {
                        val bytes = zis.readBytes()
                        val content = String(bytes, Charsets.UTF_8)
                        packageConfig = JSONObject(content)
                        entry = zis.nextEntry
                        continue
                    }

                    // Collect JS files
                    if (entryName.endsWith(".js")) {
                        jsFiles.add(entryName)
                    }

                    entry = zis.nextEntry
                }
            }
        } catch (e: Exception) {
            return ImportResult(false, "", "", "", 0, "Failed to read archive: ${e.message}")
        }

        // Determine package name
        if (packageName.isBlank()) {
            packageName = fallbackName.ifBlank {
                zipFile.nameWithoutExtension.removeSuffix(".mrm")
            }.ifBlank { "unnamed" }
        }
        if (displayName.isBlank()) displayName = packageName

        if (jsFiles.isEmpty()) {
            return ImportResult(false, packageName, displayName, version, 0,
                "No .js files found in package")
        }

        // Create package directory
        val pkgDir = File(moduleDir, packageName)
        val overwrite = manifest?.optBoolean("overwrite", true) ?: true

        if (pkgDir.exists()) {
            if (overwrite) {
                hookRegistry.log("[Importer] Overwriting existing package: $packageName")
                pkgDir.deleteRecursively()
            } else {
                return ImportResult(false, packageName, displayName, version, 0,
                    "Package '$packageName' already exists and overwrite=false")
            }
        }
        pkgDir.mkdirs()

        // Second pass: extract files
        try {
            ZipInputStream(zipFile.inputStream(), Charsets.UTF_8).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val entryName = entry.name
                    if (entryName.endsWith("/") || entryName.contains("..") || entryName.startsWith("/")) {
                        entry = zis.nextEntry
                        continue
                    }

                    // Skip manifest and config (handled separately)
                    if (entryName == MANIFEST_FILE || entryName.endsWith("/$MANIFEST_FILE") ||
                        entryName == CONFIG_FILE || entryName.endsWith("/$CONFIG_FILE")) {
                        entry = zis.nextEntry
                        continue
                    }

                    val outFile = File(pkgDir, entryName)
                    outFile.parentFile?.mkdirs()
                    outFile.outputStream().use { output -> zis.copyTo(output) }
                    extractedFiles.add(entryName)
                    entry = zis.nextEntry
                }
            }
        } catch (e: Exception) {
            return ImportResult(false, packageName, displayName, version, 0,
                "Extraction failed: ${e.message}")
        }

        // Write manifest to package directory
        if (manifest != null) {
            File(pkgDir, MANIFEST_FILE).writeText(manifest.toString(2))
        } else {
            // Write a minimal manifest
            val miniManifest = JSONObject()
                .put("name", packageName)
                .put("displayName", displayName)
                .put("version", version)
            File(pkgDir, MANIFEST_FILE).writeText(miniManifest.toString(2))
        }

        // Merge package config into shared config
        if (packageConfig != null) {
            mergeConfig(packageName, packageConfig)
        }

        hookRegistry.log("[Importer] Imported '$packageName' v$version: ${jsFiles.size} JS files, ${extractedFiles.size} total files")
        jsFiles.forEach { hookRegistry.log("[Importer]   - $it") }

        return ImportResult(
            success = true,
            packageName = packageName,
            displayName = displayName,
            version = version,
            jsFileCount = jsFiles.size,
            message = "Imported '$displayName' v$version (${jsFiles.size} modules)"
        )
    }

    /**
     * Merge a package's config values into the shared config.json.
     * Existing values are overwritten by the package's values.
     */
    private fun mergeConfig(packageName: String, packageConfig: JSONObject) {
        val keys = packageConfig.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            moduleApi.configSet(key, packageConfig.optString(key, ""), packageName)
        }
        hookRegistry.log("[Importer] Merged config from $packageName")
    }

    /**
     * Delete a module package by name.
     */
    fun deletePackage(packageName: String): Boolean {
        val pkgDir = File(moduleDir, packageName)
        if (!pkgDir.exists()) return false
        val deleted = pkgDir.deleteRecursively()
        if (deleted) hookRegistry.log("[Importer] Deleted package: $packageName")
        return deleted
    }

    /**
     * List all installed module packages with their metadata.
     */
    fun listPackages(): List<PackageSummary> {
        if (!moduleDir.exists()) return emptyList()
        return moduleDir.listFiles { file -> file.isDirectory }?.map { dir ->
            val manifestFile = File(dir, MANIFEST_FILE)
            val manifest = if (manifestFile.exists()) {
                try { JSONObject(manifestFile.readText()) } catch (_: Exception) { null }
            } else null
            val jsCount = dir.listFiles { _, name -> name.endsWith(".js") }?.size ?: 0
            PackageSummary(
                name = dir.name,
                displayName = manifest?.optString("displayName", dir.name) ?: dir.name,
                version = manifest?.optString("version", "1.0.0") ?: "1.0.0",
                description = manifest?.optString("description", "") ?: "",
                author = manifest?.optString("author", "") ?: "",
                jsFileCount = jsCount,
                directory = dir
            )
        }?.sortedBy { it.name } ?: emptyList()
    }

    data class PackageSummary(
        val name: String,
        val displayName: String,
        val version: String,
        val description: String,
        val author: String,
        val jsFileCount: Int,
        val directory: File
    )

    // ── Export ─────────────────────────────────────────────────────

    /**
     * Export a single package as a .mrm (ZIP) file to the given content URI.
     * The user picks the destination via SAF (Storage Access Framework).
     */
    fun exportPackage(packageName: String, outputUri: Uri): Boolean {
        val pkgDir = File(moduleDir, packageName)
        if (!pkgDir.exists()) {
            hookRegistry.log("[Exporter] Package not found: $packageName")
            return false
        }
        return try {
            context.contentResolver.openOutputStream(outputUri)?.use { out ->
                zipDirectory(pkgDir, out)
                true
            } ?: false
        } catch (e: Exception) {
            hookRegistry.log("[Exporter] Export failed: ${e.message}")
            false
        }
    }

    /**
     * Export all installed packages as a single .mrm (ZIP) file.
     */
    fun exportAllPackages(outputUri: Uri): Boolean {
        if (!moduleDir.exists()) return false
        val packages = moduleDir.listFiles { f -> f.isDirectory } ?: return false
        if (packages.isEmpty()) return false
        return try {
            context.contentResolver.openOutputStream(outputUri)?.use { out ->
                val zos = ZipOutputStream(out, Charsets.UTF_8)
                packages.sortedBy { it.name }.forEach { pkgDir ->
                    addDirToZip(zos, pkgDir, pkgDir.name)
                }
                zos.close()
                true
            } ?: false
        } catch (e: Exception) {
            hookRegistry.log("[Exporter] Export all failed: ${e.message}")
            false
        }
    }

    /**
     * List all files in a package directory (for the file viewer UI).
     */
    fun listFilesInPackage(packageName: String): List<PackageFile> {
        val pkgDir = File(moduleDir, packageName)
        if (!pkgDir.exists()) return emptyList()
        return pkgDir.walkTopDown()
            .filter { it.isFile }
            .map { file ->
                val relPath = pkgDir.toURI().relativize(file.toURI()).path
                PackageFile(
                    name = file.name,
                    relativePath = relPath,
                    size = file.length(),
                    content = if (file.name.endsWith(".js") || file.name.endsWith(".json")) {
                        file.readText()
                    } else null,
                    isEditable = file.name.endsWith(".js") || file.name.endsWith(".json")
                )
            }
            .sortedBy { it.relativePath }
            .toList()
    }

    /**
     * Read a specific file's content from a package (for viewing/editing).
     */
    fun readPackageFile(packageName: String, relativePath: String): String? {
        val file = File(File(moduleDir, packageName), relativePath)
        if (!file.exists() || !file.isFile) return null
        return try { file.readText() } catch (e: Exception) { null }
    }

    /**
     * Write content back to a file in a package (for in-app editing).
     */
    fun writePackageFile(packageName: String, relativePath: String, content: String): Boolean {
        val file = File(File(moduleDir, packageName), relativePath)
        return try {
            file.parentFile?.mkdirs()
            file.writeText(content)
            hookRegistry.log("[Exporter] Saved: $packageName/$relativePath")
            true
        } catch (e: Exception) {
            hookRegistry.log("[Exporter] Write failed: ${e.message}")
            false
        }
    }

    data class PackageFile(
        val name: String,
        val relativePath: String,
        val size: Long,
        val content: String?,
        val isEditable: Boolean
    )

    // ── Manifest settings (auto-rendered UI) ─────────────────────

    /**
     * Read declared settings from a package's manifest.json.
     * Returns a list of ManifestSetting for the UI to render.
     */
    fun getPackageSettings(packageName: String): List<Pair<String, JSONObject>> {
        val pkgDir = File(moduleDir, packageName)
        val manifestFile = File(pkgDir, MANIFEST_FILE)
        if (!manifestFile.exists()) return emptyList()

        val manifest = try { JSONObject(manifestFile.readText()) } catch (_: Exception) { return emptyList() }
        val settingsArray = manifest.optJSONArray("settings") ?: return emptyList()

        val result = mutableListOf<Pair<String, JSONObject>>()
        for (i in 0 until settingsArray.length()) {
            val setting = settingsArray.optJSONObject(i) ?: continue
            val key = setting.optString("key", "")
            if (key.isNotEmpty()) {
                result.add(key to setting)
            }
        }
        return result
    }

    /**
     * Read a config value from the shared config.json.
     * 自动加上包名前缀，实现模块间隔离。
     */
    fun getConfigValue(packageName: String, key: String, default: String = ""): String {
        return moduleApi.configGet(key, default, packageName)
    }

    /**
     * Write a config value to the shared config.json (in-memory + persist).
     * 自动加上包名前缀，实现模块间隔离。
     */
    fun setConfigValue(packageName: String, key: String, value: String) {
        moduleApi.configSet(key, value, packageName)
    }

    /**
     * Persist the shared config (no-op if already saved by setConfigValue).
     */
    fun saveConfig() {
        moduleApi.configSave()
        hookRegistry.log("[Importer] Config saved")
    }

    // ── Zip helpers ──────────────────────────────────────────────────

    private fun zipDirectory(dir: File, output: OutputStream) {
        val zos = ZipOutputStream(output, Charsets.UTF_8)
        addDirToZip(zos, dir, "")
        zos.close()
    }

    private fun addDirToZip(zos: ZipOutputStream, dir: File, basePath: String) {
        dir.listFiles()?.sortedBy { it.name }?.forEach { file ->
            val entryPath = if (basePath.isEmpty()) file.name else "$basePath/${file.name}"
            if (file.isDirectory) {
                addDirToZip(zos, file, entryPath)
            } else {
                zos.putNextEntry(java.util.zip.ZipEntry(entryPath))
                file.inputStream().use { it.copyTo(zos) }
                zos.closeEntry()
            }
        }
    }
}
