package com.mozhi.reader.feature.settings

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.mozhi.reader.ui.components.MoReadBlock
import com.mozhi.reader.ui.components.MoReadRow
import com.mozhi.reader.ui.components.MoReadRowDivider
import com.mozhi.reader.ui.components.MoReadSection

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModuleSettingsScreen(
    onBack: () -> Unit,
    viewModel: ModuleSettingsViewModel = hiltViewModel()
) {
    val packages by viewModel.packages.collectAsStateWithLifecycle()
    val isLoading by viewModel.isLoading.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val logs by viewModel.logs.collectAsStateWithLifecycle()

    val viewingPackage by viewModel.viewingPackage.collectAsStateWithLifecycle()
    val packageFiles by viewModel.packageFiles.collectAsStateWithLifecycle()
    val viewingFile by viewModel.viewingFile.collectAsStateWithLifecycle()
    val editingContent by viewModel.editingContent.collectAsStateWithLifecycle()
    val isEditing by viewModel.isEditing.collectAsStateWithLifecycle()

    val pendingExportPackage by viewModel.pendingExportPackage.collectAsStateWithLifecycle()
    val pendingExportAll by viewModel.pendingExportAll.collectAsStateWithLifecycle()
    val pendingExportLogs by viewModel.pendingExportLogs.collectAsStateWithLifecycle()

    // SAF launcher for importing .mrm files
    val importPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri != null) viewModel.importModule(uri)
    }

    // SAF launcher for exporting a single package
    val exportSinglePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? ->
        if (uri != null) viewModel.exportPackageToUri(uri)
    }

    // SAF launcher for exporting all packages
    val exportAllPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? ->
        if (uri != null) viewModel.exportAllToUri(uri)
    }

    // SAF launcher for exporting logs
    val exportLogsPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/plain")
    ) { uri: Uri? ->
        if (uri != null) viewModel.exportLogsToUri(uri)
    }

    // React to pending export requests
    LaunchedEffect(pendingExportPackage) {
        pendingExportPackage?.let { pkgName ->
            exportSinglePicker.launch("$pkgName.mrm")
        }
    }
    LaunchedEffect(pendingExportAll) {
        if (pendingExportAll) {
            exportAllPicker.launch("all-modules.mrm")
        }
    }
    LaunchedEffect(pendingExportLogs) {
        if (pendingExportLogs) {
            exportLogsPicker.launch("moread-logs.txt")
        }
    }

    LaunchedEffect(message) {
        message?.let {
            kotlinx.coroutines.delay(3000)
            viewModel.clearMessage()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("模块管理") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.reloadAll() }) {
                        Icon(Icons.Outlined.Refresh, contentDescription = "重新加载")
                    }
                }
            )
        }
    ) { padding ->
        if (isLoading) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth().padding(padding))
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Import + Export buttons
            item {
                MoReadSection(title = "模块包", icon = Icons.Outlined.Extension) {
                    MoReadRow(
                        icon = Icons.Outlined.Upload,
                        title = "导入模块包",
                        subtitle = "选择 .mrm 或 .zip 文件导入",
                        onClick = {
                            importPicker.launch(arrayOf("application/zip", "application/octet-stream", "*/*"))
                        }
                    )
                    MoReadRowDivider()
                    MoReadRow(
                        icon = Icons.Outlined.Download,
                        title = "导出全部模块",
                        subtitle = if (packages.isEmpty()) "暂无已安装模块" else "将 ${packages.size} 个模块包打包为 .mrm",
                        onClick = { viewModel.requestExportAll() }
                    )
                    MoReadRowDivider()
                    MoReadRow(
                        icon = Icons.Outlined.Refresh,
                        title = "重新加载全部模块",
                        subtitle = "重新扫描并执行所有模块",
                        onClick = { viewModel.reloadAll() }
                    )
                }
            }

            // Module directory path (for root users)
            item {
                MoReadBlock(title = "模块目录（内部存储）") {
                    Text(
                        text = viewModel.moduleDirPath,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                    )
                    Text(
                        text = "Root 用户可直接编辑此目录下的文件；非 Root 用户可导出后修改再导入。",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                    )
                }
            }

            // Installed packages
            if (packages.isNotEmpty()) {
                item {
                    MoReadSection(title = "已安装模块 (${packages.size})", icon = Icons.Outlined.Folder) {
                        packages.forEachIndexed { index, pkg ->
                            if (index > 0) MoReadRowDivider()
                            MoReadRow(
                                icon = Icons.Outlined.Extension,
                                title = pkg.displayName,
                                subtitle = buildString {
                                    append("v${pkg.version}")
                                    append(" · ${pkg.jsFileCount} 个模块")
                                    if (pkg.author.isNotBlank()) append(" · ${pkg.author}")
                                    if (pkg.description.isNotBlank()) append("\n${pkg.description}")
                                },
                                trailing = {
                                    Row {
                                        // View files button
                                        IconButton(onClick = { viewModel.openPackageFiles(pkg.name) }) {
                                            Icon(Icons.Outlined.Code, contentDescription = "查看源码")
                                        }
                                        // Export button
                                        IconButton(onClick = { viewModel.requestExportPackage(pkg.name) }) {
                                            Icon(Icons.Outlined.Download, contentDescription = "导出")
                                        }
                                        // Delete button
                                        IconButton(onClick = { viewModel.deletePackage(pkg.name) }) {
                                            Icon(
                                                Icons.Outlined.Delete,
                                                contentDescription = "删除",
                                                tint = MaterialTheme.colorScheme.error
                                            )
                                        }
                                    }
                                }
                            )
                        }
                    }
                }
            }

            // Message
            message?.let {
                item {
                    MoReadBlock(title = "操作结果") {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }

            // Logs (always visible — shows action buttons even when empty)
            item {
                MoReadBlock(title = "模块日志 (${logs.size} 条)") {
                    // Action buttons row
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        // Copy
                        TextButton(
                            onClick = { viewModel.copyLogs() },
                            enabled = logs.isNotEmpty()
                        ) {
                            Icon(Icons.Outlined.ContentCopy, contentDescription = null,
                                modifier = Modifier.size(18.dp))
                            Text(" 复制", style = MaterialTheme.typography.labelSmall)
                        }
                        // Export
                        TextButton(
                            onClick = { viewModel.requestExportLogs() },
                            enabled = logs.isNotEmpty()
                        ) {
                            Icon(Icons.Outlined.Download, contentDescription = null,
                                modifier = Modifier.size(18.dp))
                            Text(" 导出", style = MaterialTheme.typography.labelSmall)
                        }
                        // Clear
                        TextButton(
                            onClick = { viewModel.clearLogs() },
                            enabled = logs.isNotEmpty()
                        ) {
                            Icon(Icons.Outlined.Delete, contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(18.dp))
                            Text(" 清空", style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.error)
                        }
                    }

                    // Log content
                    if (logs.isEmpty()) {
                        Text(
                            text = "暂无日志",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
                        )
                    } else {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 400.dp)
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 16.dp, vertical = 4.dp)
                        ) {
                            logs.takeLast(60).forEach { log ->
                                Text(
                                    text = log,
                                    style = MaterialTheme.typography.bodySmall,
                                    fontFamily = FontFamily.Monospace,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(vertical = 2.dp)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // ── File list dialog ──────────────────────────────────────────

    if (viewingPackage != null && viewingFile == null) {
        AlertDialog(
            onDismissRequest = { viewModel.closePackageFiles() },
            title = { Text("文件列表 — $viewingPackage") },
            text = {
                LazyColumn(
                    modifier = Modifier.heightIn(max = 400.dp)
                ) {
                    items(packageFiles) { file ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { viewModel.viewFile(file) }
                                .padding(vertical = 8.dp, horizontal = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(
                                Icons.Outlined.Code,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.primary
                            )
                            Column {
                                Text(
                                    text = file.name,
                                    style = MaterialTheme.typography.bodyMedium
                                )
                                Text(
                                    text = "${formatFileSize(file.size)} · ${file.relativePath}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { viewModel.closePackageFiles() }) { Text("关闭") }
            }
        )
    }

    // ── File viewer / editor dialog ────────────────────────────────

    viewingFile?.let { file ->
        AlertDialog(
            onDismissRequest = { viewModel.closeFileViewer() },
            title = { Text(file.name) },
            text = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    if (isEditing) {
                        OutlinedTextField(
                            value = editingContent,
                            onValueChange = { viewModel.updateContent(it) },
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 400.dp)
                                .verticalScroll(rememberScrollState()),
                            textStyle = MaterialTheme.typography.bodySmall.copy(
                                fontFamily = FontFamily.Monospace
                            )
                        )
                    } else {
                        Text(
                            text = file.content ?: "(无法显示此文件类型)",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 400.dp)
                                .verticalScroll(rememberScrollState())
                        )
                    }
                }
            },
            confirmButton = {
                if (file.isEditable) {
                    if (isEditing) {
                        Row {
                            TextButton(onClick = { viewModel.cancelEditing() }) { Text("取消") }
                            TextButton(onClick = { viewModel.saveEditedFile() }) {
                                Icon(Icons.Outlined.Save, contentDescription = null)
                                Text(" 保存")
                            }
                        }
                    } else {
                        Row {
                            TextButton(onClick = { viewModel.closeFileViewer() }) { Text("关闭") }
                            TextButton(onClick = { viewModel.startEditing() }) {
                                Icon(Icons.Outlined.Edit, contentDescription = null)
                                Text(" 编辑")
                            }
                        }
                    }
                } else {
                    TextButton(onClick = { viewModel.closeFileViewer() }) { Text("关闭") }
                }
            }
        )
    }
}

private fun formatFileSize(bytes: Long): String {
    return when {
        bytes < 1024 -> "${bytes}B"
        bytes < 1024 * 1024 -> "${bytes / 1024}KB"
        else -> "${bytes / (1024 * 1024)}MB"
    }
}
