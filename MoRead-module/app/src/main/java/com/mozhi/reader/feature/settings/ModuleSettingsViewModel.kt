package com.mozhi.reader.feature.settings

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mozhi.reader.modules.HookRegistry
import com.mozhi.reader.modules.ModuleImporter
import com.mozhi.reader.modules.ModuleLoader
import dagger.hilt.android.lifecycle.HiltViewModel
import org.json.JSONObject
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

@HiltViewModel
class ModuleSettingsViewModel @Inject constructor(
    private val app: Application,
    private val moduleImporter: ModuleImporter,
    private val moduleLoader: ModuleLoader,
    private val hookRegistry: HookRegistry
) : AndroidViewModel(app) {

    private val _packages = MutableStateFlow<List<ModuleImporter.PackageSummary>>(emptyList())
    val packages: StateFlow<List<ModuleImporter.PackageSummary>> = _packages.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _message = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = _message.asStateFlow()

    private val _logs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = _logs.asStateFlow()

    // ── Master switch ──────────────────────────────────────────────

    private val _modulesEnabled = MutableStateFlow(true)
    val modulesEnabled: StateFlow<Boolean> = _modulesEnabled.asStateFlow()

    // ── Per-package enabled map ────────────────────────────────────

    private val _packageEnabled = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    val packageEnabled: StateFlow<Map<String, Boolean>> = _packageEnabled.asStateFlow()

    // ── Multi-select state ─────────────────────────────────────────

    private val _multiSelectMode = MutableStateFlow(false)
    val multiSelectMode: StateFlow<Boolean> = _multiSelectMode.asStateFlow()

    private val _selectedPackages = MutableStateFlow<Set<String>>(emptySet())
    val selectedPackages: StateFlow<Set<String>> = _selectedPackages.asStateFlow()

    // ── File viewer state ──────────────────────────────────────────

    private val _viewingPackage = MutableStateFlow<String?>(null)
    val viewingPackage: StateFlow<String?> = _viewingPackage.asStateFlow()

    private val _packageFiles = MutableStateFlow<List<ModuleImporter.PackageFile>>(emptyList())
    val packageFiles: StateFlow<List<ModuleImporter.PackageFile>> = _packageFiles.asStateFlow()

    private val _viewingFile = MutableStateFlow<ModuleImporter.PackageFile?>(null)
    val viewingFile: StateFlow<ModuleImporter.PackageFile?> = _viewingFile.asStateFlow()

    private val _editingContent = MutableStateFlow<String>("")
    val editingContent: StateFlow<String> = _editingContent.asStateFlow()

    private val _isEditing = MutableStateFlow(false)
    val isEditing: StateFlow<Boolean> = _isEditing.asStateFlow()

    // ── Pending export (needs SAF callback) ───────────────────────

    private val _pendingExportPackage = MutableStateFlow<String?>(null)
    val pendingExportPackage: StateFlow<String?> = _pendingExportPackage.asStateFlow()

    private val _pendingExportAll = MutableStateFlow(false)
    val pendingExportAll: StateFlow<Boolean> = _pendingExportAll.asStateFlow()

    private val _pendingExportLogs = MutableStateFlow(false)
    val pendingExportLogs: StateFlow<Boolean> = _pendingExportLogs.asStateFlow()

    // ── Package settings (manifest-declared UI) ───────────────────

    private val _viewingSettingsPackage = MutableStateFlow<String?>(null)
    val viewingSettingsPackage: StateFlow<String?> = _viewingSettingsPackage.asStateFlow()

    private val _packageSettings = MutableStateFlow<List<Pair<String, JSONObject>>>(emptyList())
    val packageSettings: StateFlow<List<Pair<String, JSONObject>>> = _packageSettings.asStateFlow()

    private val _settingValues = MutableStateFlow<Map<String, String>>(emptyMap())
    val settingValues: StateFlow<Map<String, String>> = _settingValues.asStateFlow()

    val moduleDirPath: String get() = moduleImporter.moduleDir.absolutePath
    val packageName: String get() = app.packageName

    fun isBuiltInPackage(pkgName: String): Boolean = moduleLoader.isBuiltInPackage(pkgName)

    init {
        refresh()
    }

    fun refresh() {
        _packages.value = moduleImporter.listPackages()
        _logs.value = hookRegistry.getLogs()
        _modulesEnabled.value = moduleLoader.isModulesEnabled()
        _packageEnabled.value = _packages.value.associate { pkg ->
            pkg.name to moduleLoader.isPackageEnabled(pkg.name)
        }
    }

    // ── Master switch ──────────────────────────────────────────────

    fun setModulesEnabled(enabled: Boolean) {
        moduleLoader.setModulesEnabled(enabled)
        _modulesEnabled.value = enabled
        if (enabled) {
            reloadAll()
        } else {
            viewModelScope.launch(Dispatchers.IO) {
                _isLoading.value = true
                val result = moduleLoader.loadAll()
                _message.value = result.message
                refresh()
                _isLoading.value = false
            }
        }
    }

    // ── Per-package switch ─────────────────────────────────────────

    fun setPackageEnabled(packageName: String, enabled: Boolean) {
        moduleLoader.setPackageEnabled(packageName, enabled)
        _packageEnabled.value = _packageEnabled.value.toMutableMap().apply {
            put(packageName, enabled)
        }
        reloadAll()
    }

    // ── Multi-select ───────────────────────────────────────────────

    fun toggleMultiSelectMode() {
        _multiSelectMode.value = !_multiSelectMode.value
        if (!_multiSelectMode.value) {
            _selectedPackages.value = emptySet()
        }
    }

    fun togglePackageSelection(packageName: String) {
        _selectedPackages.value = _selectedPackages.value.toMutableSet().apply {
            if (contains(packageName)) remove(packageName) else add(packageName)
        }
    }

    fun selectAllPackages() {
        // Select only non-built-in packages (built-in can't be deleted anyway)
        _selectedPackages.value = _packages.value
            .filter { !moduleLoader.isBuiltInPackage(it.name) }
            .map { it.name }
            .toSet()
    }

    fun deselectAllPackages() {
        _selectedPackages.value = emptySet()
    }

    fun batchEnable() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            _selectedPackages.value.forEach { pkg ->
                moduleLoader.setPackageEnabled(pkg, true)
            }
            val result = moduleLoader.loadAll()
            _message.value = "已启用 ${_selectedPackages.value.size} 个模块\n${result.message}"
            _multiSelectMode.value = false
            _selectedPackages.value = emptySet()
            refresh()
            _isLoading.value = false
        }
    }

    fun batchDisable() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            _selectedPackages.value.forEach { pkg ->
                moduleLoader.setPackageEnabled(pkg, false)
            }
            val result = moduleLoader.loadAll()
            _message.value = "已禁用 ${_selectedPackages.value.size} 个模块\n${result.message}"
            _multiSelectMode.value = false
            _selectedPackages.value = emptySet()
            refresh()
            _isLoading.value = false
        }
    }

    fun batchDelete() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            var deleted = 0
            var skippedBuiltIn = 0
            _selectedPackages.value.forEach { pkg ->
                if (moduleLoader.isBuiltInPackage(pkg)) {
                    skippedBuiltIn++
                } else if (moduleImporter.deletePackage(pkg)) {
                    deleted++
                }
            }
            moduleLoader.loadAll()
            val msg = buildString {
                append("已删除 $deleted 个模块包")
                if (skippedBuiltIn > 0) append("，跳过 $skippedBuiltIn 个内置模块（不可删除）")
            }
            _message.value = msg
            _multiSelectMode.value = false
            _selectedPackages.value = emptySet()
            refresh()
            _isLoading.value = false
        }
    }

    // ── Import / Reload / Delete ──────────────────────────────────

    fun importModule(uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val result = moduleImporter.importFromUri(uri)
            _message.value = result.message
            if (result.success) {
                val loadResult = moduleLoader.loadAll()
                _message.value = "${result.message}\n${loadResult.message}"
            }
            refresh()
            _isLoading.value = false
        }
    }

    fun reloadAll() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val result = moduleLoader.loadAll()
            _message.value = result.message
            refresh()
            _isLoading.value = false
        }
    }

    fun deletePackage(packageName: String) {
        viewModelScope.launch(Dispatchers.IO) {
            if (moduleLoader.isBuiltInPackage(packageName)) {
                _message.value = "内置模块不可删除：$packageName"
                return@launch
            }
            val success = moduleImporter.deletePackage(packageName)
            _message.value = if (success) "已删除模块包：$packageName" else "删除失败：$packageName"
            if (success) {
                moduleLoader.loadAll()
            }
            refresh()
        }
    }

    // ── Export ─────────────────────────────────────────────────────

    fun requestExportPackage(packageName: String) {
        _pendingExportPackage.value = packageName
    }

    fun requestExportAll() {
        _pendingExportAll.value = true
    }

    fun exportPackageToUri(uri: Uri) {
        val packageName = _pendingExportPackage.value
        _pendingExportPackage.value = null
        if (packageName == null) return

        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val success = moduleImporter.exportPackage(packageName, uri)
            _message.value = if (success) "已导出模块包：$packageName.mrm" else "导出失败：$packageName"
            _isLoading.value = false
        }
    }

    fun exportAllToUri(uri: Uri) {
        _pendingExportAll.value = false
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val success = moduleImporter.exportAllPackages(uri)
            _message.value = if (success) "已导出全部模块包" else "导出失败"
            _isLoading.value = false
        }
    }

    // ── File viewer ────────────────────────────────────────────────

    fun openPackageFiles(packageName: String) {
        viewModelScope.launch(Dispatchers.IO) {
            _viewingPackage.value = packageName
            _packageFiles.value = moduleImporter.listFilesInPackage(packageName)
        }
    }

    fun closePackageFiles() {
        _viewingPackage.value = null
        _packageFiles.value = emptyList()
        _viewingFile.value = null
        _editingContent.value = ""
        _isEditing.value = false
    }

    fun viewFile(file: ModuleImporter.PackageFile) {
        _viewingFile.value = file
        _editingContent.value = file.content ?: ""
        _isEditing.value = false
    }

    fun startEditing() {
        _isEditing.value = true
    }

    fun updateContent(content: String) {
        _editingContent.value = content
    }

    fun saveEditedFile() {
        val packageName = _viewingPackage.value ?: return
        val file = _viewingFile.value ?: return
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val saved = moduleImporter.writePackageFile(packageName, file.relativePath, _editingContent.value)
            if (saved) {
                _packageFiles.value = moduleImporter.listFilesInPackage(packageName)
                _viewingFile.value = _viewingFile.value?.copy(content = _editingContent.value)
                val loadResult = moduleLoader.loadAll()
                _message.value = "已保存：${file.name}\n${loadResult.message}"
            } else {
                _message.value = "保存失败：${file.name}"
            }
            _isEditing.value = false
            _isLoading.value = false
        }
    }

    fun cancelEditing() {
        _isEditing.value = false
        _viewingFile.value?.let { _editingContent.value = it.content ?: "" }
    }

    fun closeFileViewer() {
        _viewingFile.value = null
        _editingContent.value = ""
        _isEditing.value = false
    }

    fun clearMessage() {
        _message.value = null
    }

    // ── Log operations ─────────────────────────────────────────────

    fun clearLogs() {
        hookRegistry.clearLogs()
        refresh()
    }

    fun copyLogs() {
        val text = hookRegistry.getLogsText()
        if (text.isEmpty()) {
            _message.value = "日志为空"
            return
        }
        val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("MoRead Logs", text))
        _message.value = "已复制 ${hookRegistry.getLogs().size} 条日志到剪贴板"
    }

    fun requestExportLogs() {
        _pendingExportLogs.value = true
    }

    fun exportLogsToUri(uri: Uri) {
        _pendingExportLogs.value = false
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            try {
                val text = hookRegistry.getLogsText()
                app.contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(text.toByteArray(Charsets.UTF_8))
                }
                _message.value = "已导出 ${hookRegistry.getLogs().size} 条日志"
            } catch (e: Exception) {
                _message.value = "导出日志失败: ${e.message}"
            }
            _isLoading.value = false
        }
    }

    // ── Package settings (manifest-declared UI) ───────────────────

    fun openPackageSettings(packageName: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val settings = moduleImporter.getPackageSettings(packageName)
            _viewingSettingsPackage.value = packageName
            _packageSettings.value = settings
            // 初始化设置值缓存，让 UI 能响应式更新
            val values = settings.associate { (key, setting) ->
                key to moduleImporter.getConfigValue(key, setting.optString("default", ""))
            }
            _settingValues.value = values
        }
    }

    fun closePackageSettings() {
        _viewingSettingsPackage.value = null
        _packageSettings.value = emptyList()
        _settingValues.value = emptyMap()
    }

    fun setSettingValue(key: String, value: String) {
        _settingValues.value = _settingValues.value.toMutableMap().apply {
            put(key, value)
        }
        viewModelScope.launch(Dispatchers.IO) {
            moduleImporter.setConfigValue(key, value)
        }
    }

    fun saveSettings() {
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            moduleImporter.saveConfig()
            val pkgName = _viewingSettingsPackage.value
            if (pkgName != null) {
                val loadResult = moduleLoader.loadAll()
                _message.value = "设置已保存\n${loadResult.message}"
            }
            _isLoading.value = false
        }
    }

    fun getConfigValue(key: String, default: String): String {
        return moduleImporter.getConfigValue(key, default)
    }
}
