package com.mozhi.reader.feature.settings

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.mozhi.reader.modules.HookRegistry
import com.mozhi.reader.modules.ModuleImporter
import com.mozhi.reader.modules.ModuleLoader
import dagger.hilt.android.lifecycle.HiltViewModel
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

    val moduleDirPath: String get() = moduleImporter.moduleDir.absolutePath

    init {
        refresh()
    }

    fun refresh() {
        _packages.value = moduleImporter.listPackages()
        _logs.value = hookRegistry.getLogs()
    }

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
            val success = moduleImporter.deletePackage(packageName)
            _message.value = if (success) "已删除模块包：$packageName" else "删除失败：$packageName"
            if (success) {
                moduleLoader.loadAll()
            }
            refresh()
        }
    }

    // ── Export ─────────────────────────────────────────────────────

    /**
     * Request to export a single package. Triggers SAF file picker.
     * The UI calls [exportPackageToUri] with the chosen URI.
     */
    fun requestExportPackage(packageName: String) {
        _pendingExportPackage.value = packageName
    }

    /**
     * Request to export all packages. Triggers SAF file picker.
     */
    fun requestExportAll() {
        _pendingExportAll.value = true
    }

    /**
     * Actually export the pending package to the chosen URI.
     */
    fun exportPackageToUri(uri: Uri) {
        val packageName = _pendingExportPackage.value
        _pendingExportPackage.value = null
        if (packageName == null) return

        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val success = moduleImporter.exportPackage(packageName, uri)
            _message.value = if (success) {
                "已导出模块包：$packageName.mrm"
            } else {
                "导出失败：$packageName"
            }
            _isLoading.value = false
        }
    }

    /**
     * Actually export all packages to the chosen URI.
     */
    fun exportAllToUri(uri: Uri) {
        _pendingExportAll.value = false
        viewModelScope.launch(Dispatchers.IO) {
            _isLoading.value = true
            val success = moduleImporter.exportAllPackages(uri)
            _message.value = if (success) {
                "已导出全部模块包"
            } else {
                "导出失败"
            }
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
                // Refresh file list and viewing content
                _packageFiles.value = moduleImporter.listFilesInPackage(packageName)
                _viewingFile.value = _viewingFile.value?.copy(content = _editingContent.value)

                // Hot-reload: re-execute all modules so the edited code takes effect immediately
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
}
