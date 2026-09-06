package com.mozhi.reader.feature.settings

import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Extension
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
    val context = androidx.compose.ui.platform.LocalContext.current
    val packages by viewModel.packages.collectAsStateWithLifecycle()
    val isLoading by viewModel.isLoading.collectAsStateWithLifecycle()
    val message by viewModel.message.collectAsStateWithLifecycle()
    val logs by viewModel.logs.collectAsStateWithLifecycle()
    val modulesEnabled by viewModel.modulesEnabled.collectAsStateWithLifecycle()
    val packageEnabled by viewModel.packageEnabled.collectAsStateWithLifecycle()
    val multiSelectMode by viewModel.multiSelectMode.collectAsStateWithLifecycle()
    val selectedPackages by viewModel.selectedPackages.collectAsStateWithLifecycle()

    val viewingPackage by viewModel.viewingPackage.collectAsStateWithLifecycle()
    val packageFiles by viewModel.packageFiles.collectAsStateWithLifecycle()
    val viewingFile by viewModel.viewingFile.collectAsStateWithLifecycle()
    val editingContent by viewModel.editingContent.collectAsStateWithLifecycle()
    val isEditing by viewModel.isEditing.collectAsStateWithLifecycle()

    val pendingExportPackage by viewModel.pendingExportPackage.collectAsStateWithLifecycle()
    val pendingExportAll by viewModel.pendingExportAll.collectAsStateWithLifecycle()
    val pendingExportLogs by viewModel.pendingExportLogs.collectAsStateWithLifecycle()

    val viewingSettingsPackage by viewModel.viewingSettingsPackage.collectAsStateWithLifecycle()
    val packageSettings by viewModel.packageSettings.collectAsStateWithLifecycle()
    val settingValues by viewModel.settingValues.collectAsStateWithLifecycle()
    val moduleLogs by viewModel.moduleLogs.collectAsStateWithLifecycle()

    // SAF launchers
    val importPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri -> if (uri != null) viewModel.importModule(uri) }

    val exportSinglePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? -> if (uri != null) viewModel.exportPackageToUri(uri) }

    val exportAllPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? -> if (uri != null) viewModel.exportAllToUri(uri) }

    val exportLogsPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.CreateDocument("text/plain")
    ) { uri: Uri? -> if (uri != null) viewModel.exportLogsToUri(uri) }

    LaunchedEffect(pendingExportPackage) {
        pendingExportPackage?.let { exportSinglePicker.launch("$it.mrm") }
    }
    LaunchedEffect(pendingExportAll) {
        if (pendingExportAll) exportAllPicker.launch("all-modules.mrm")
    }
    LaunchedEffect(pendingExportLogs) {
        if (pendingExportLogs) exportLogsPicker.launch("moread-logs.txt")
    }
    LaunchedEffect(message) {
        message?.let {
            Toast.makeText(context, it, Toast.LENGTH_SHORT).show()
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
                    if (packages.isNotEmpty() && !multiSelectMode) {
                        IconButton(onClick = { viewModel.toggleMultiSelectMode() }) {
                            Icon(Icons.Outlined.Checklist, contentDescription = "多选")
                        }
                    }
                    if (multiSelectMode) {
                        TextButton(onClick = { viewModel.selectAllPackages() }) { Text("全选") }
                    }
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
            // ── Master switch ────────────────────────────────────
            item {
                MoReadBlock(title = "模块系统") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("启用模块系统", style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "关闭后全部使用原生功能",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Switch(
                            checked = modulesEnabled,
                            onCheckedChange = { viewModel.setModulesEnabled(it) }
                        )
                    }
                }
            }

            // ── Import / Export / Reload ─────────────────────────
            if (modulesEnabled) {
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
            }

            // ── Module directory ─────────────────────────────────
            item {
                MoReadBlock(title = "模块目录（内部存储）") {
                    Text(
                        text = "包名: ${viewModel.packageName}",
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = FontFamily.Monospace,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp)
                    )
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

            // ── Installed packages ───────────────────────────────
            if (packages.isNotEmpty() && modulesEnabled) {
                item {
                    MoReadSection(
                        title = if (multiSelectMode) "已选 ${selectedPackages.size}/${packages.size}" else "已安装模块 (${packages.size})",
                        icon = Icons.Outlined.Folder
                    ) {
                        packages.forEachIndexed { index, pkg ->
                            if (index > 0) MoReadRowDivider()
                            val isEnabled = packageEnabled[pkg.name] ?: true
                            val isSelected = pkg.name in selectedPackages

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        if (multiSelectMode) viewModel.togglePackageSelection(pkg.name)
                                    }
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                // Checkbox in multi-select mode
                                if (multiSelectMode) {
                                    val builtIn = viewModel.isBuiltInPackage(pkg.name)
                                    Checkbox(
                                        checked = if (builtIn) false else isSelected,
                                        onCheckedChange = {
                                            if (!builtIn) viewModel.togglePackageSelection(pkg.name)
                                        },
                                        modifier = Modifier.padding(end = 8.dp),
                                        enabled = !builtIn
                                    )
                                }

                                // Icon + text
                                Icon(
                                    Icons.Outlined.Extension,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary
                                )
                                Column(
                                    modifier = Modifier
                                        .weight(1f)
                                        .padding(horizontal = 12.dp)
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = pkg.displayName,
                                            style = MaterialTheme.typography.bodyMedium
                                        )
                                        if (viewModel.isBuiltInPackage(pkg.name)) {
                                            Spacer(Modifier.width(6.dp))
                                            Surface(
                                                color = MaterialTheme.colorScheme.primaryContainer,
                                                shape = MaterialTheme.shapes.small,
                                            ) {
                                                Text(
                                                    text = "内置",
                                                    style = MaterialTheme.typography.labelSmall,
                                                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp)
                                                )
                                            }
                                        }
                                    }
                                    Text(
                                        text = buildString {
                                            append("v${pkg.version}")
                                            append(" · ${pkg.jsFileCount} 个模块")
                                            if (pkg.author.isNotBlank()) append(" · ${pkg.author}")
                                            if (pkg.description.isNotBlank()) append("\n${pkg.description}")
                                            if (!isEnabled) append("\n(已禁用)")
                                        },
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }

                                // Single package switch (hidden in multi-select)
                                if (!multiSelectMode) {
                                    Switch(
                                        checked = isEnabled,
                                        onCheckedChange = { viewModel.setPackageEnabled(pkg.name, it) }
                                    )
                                    // Settings button (if manifest declares settings)
                                    IconButton(onClick = { viewModel.openPackageSettings(pkg.name) }) {
                                        Icon(Icons.Outlined.Settings, contentDescription = "设置")
                                    }
                                    // View files
                                    IconButton(onClick = { viewModel.openPackageFiles(pkg.name) }) {
                                        Icon(Icons.Outlined.Code, contentDescription = "查看源码")
                                    }
                                    // Export
                                    IconButton(onClick = { viewModel.requestExportPackage(pkg.name) }) {
                                        Icon(Icons.Outlined.Download, contentDescription = "导出")
                                    }
                                    // Delete (hidden for built-in modules)
                                    if (!viewModel.isBuiltInPackage(pkg.name)) {
                                        IconButton(onClick = { viewModel.deletePackage(pkg.name) }) {
                                            Icon(
                                                Icons.Outlined.Delete,
                                                contentDescription = "删除",
                                                tint = MaterialTheme.colorScheme.error
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Batch action bar ──────────────────────────────
                if (multiSelectMode && selectedPackages.isNotEmpty()) {
                    item {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            TextButton(onClick = { viewModel.batchEnable() }) {
                                Icon(Icons.Outlined.PowerSettingsNew, contentDescription = null,
                                    modifier = Modifier.size(18.dp))
                                Text(" 批量启用", style = MaterialTheme.typography.labelSmall)
                            }
                            TextButton(onClick = { viewModel.batchDisable() }) {
                                Icon(Icons.Outlined.PowerSettingsNew, contentDescription = null,
                                    modifier = Modifier.size(18.dp))
                                Text(" 批量禁用", style = MaterialTheme.typography.labelSmall)
                            }
                            TextButton(onClick = { viewModel.batchDelete() }) {
                                Icon(Icons.Outlined.Delete, contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.size(18.dp))
                                Text(" 批量删除", style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.error)
                            }
                        }
                    }
                }
            }

            // ── Message ─────────────────────────────────────────
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

            // ── Logs ─────────────────────────────────────────────
            item {
                MoReadBlock(title = "模块日志 (${logs.size} 条)") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        TextButton(
                            onClick = { viewModel.copyLogs() },
                            enabled = logs.isNotEmpty()
                        ) {
                            Icon(Icons.Outlined.ContentCopy, contentDescription = null,
                                modifier = Modifier.size(18.dp))
                            Text(" 复制", style = MaterialTheme.typography.labelSmall)
                        }
                        TextButton(
                            onClick = { viewModel.requestExportLogs() },
                            enabled = logs.isNotEmpty()
                        ) {
                            Icon(Icons.Outlined.Download, contentDescription = null,
                                modifier = Modifier.size(18.dp))
                            Text(" 导出", style = MaterialTheme.typography.labelSmall)
                        }
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
                            logs.takeLast(60).reversed().forEach { log ->
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
                LazyColumn(modifier = Modifier.heightIn(max = 400.dp)) {
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
                                Text(file.name, style = MaterialTheme.typography.bodyMedium)
                                Text(
                                    "${formatFileSize(file.size)} · ${file.relativePath}",
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

    // ── File viewer / editor dialog ───────────────────────────────

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

    // ── Package settings dialog (manifest-declared UI) ───────────

    if (viewingSettingsPackage != null) {
        var settingsTab by remember { mutableStateOf(0) }
        AlertDialog(
            onDismissRequest = { viewModel.closePackageSettings() },
            title = { Text("设置 — $viewingSettingsPackage") },
            text = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    TabRow(selectedTabIndex = settingsTab) {
                        Tab(
                            selected = settingsTab == 0,
                            onClick = { settingsTab = 0 },
                            text = { Text("设置") }
                        )
                        Tab(
                            selected = settingsTab == 1,
                            onClick = {
                                settingsTab = 1
                                viewModel.refreshModuleLogs()
                            },
                            text = { Text("日志") }
                        )
                    }
                    if (settingsTab == 0) {
                        if (packageSettings.isEmpty()) {
                            Text("此模块没有可配置项", style = MaterialTheme.typography.bodyMedium)
                        } else {
                            Column(modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                                packageSettings.forEach { (key, setting) ->
                                    val label = setting.optString("label", key)
                                    val type = setting.optString("type", "string")
                                    val default = setting.optString("default", "")
                                    val currentVal = settingValues[key] ?: default

                                    when (type) {
                                        "password" -> {
                                            OutlinedTextField(
                                                value = currentVal,
                                                onValueChange = { viewModel.setSettingValue(key, it) },
                                                label = { Text(label) },
                                                visualTransformation = PasswordVisualTransformation(),
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp)
                                            )
                                        }
                                        "bool" -> {
                                            Row(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp),
                                                horizontalArrangement = Arrangement.SpaceBetween,
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Text(label, style = MaterialTheme.typography.bodyMedium)
                                                Switch(
                                                    checked = currentVal == "true",
                                                    onCheckedChange = {
                                                        viewModel.setSettingValue(key, if (it) "true" else "false")
                                                    }
                                                )
                                            }
                                        }
                                        "select" -> {
                                            // 解析选项：支持三种格式
                                            // 1. JSON 数组 ["a","b","c"]
                                            // 2. 管道字符串 "a|b|c"（纯值）
                                            // 3. 值|标签对，逗号分隔 "a|显示A,b|显示B"
                                            data class SelectOption(val value: String, val label: String)
                                            val options = mutableListOf<SelectOption>()
                                            val arr = setting.optJSONArray("options")
                                            if (arr != null) {
                                                for (i in 0 until arr.length()) {
                                                    val v = arr.getString(i)
                                                    options.add(SelectOption(v, v))
                                                }
                                            } else {
                                                val optStr = setting.optString("options", "")
                                                if (optStr.isNotBlank()) {
                                                    // 判断格式：含逗号且逗号分隔项里含 | → 值|标签 格式
                                                    if (optStr.contains(",") && optStr.contains("|")) {
                                                        optStr.split(",").forEach { item ->
                                                            val trimmed = item.trim()
                                                            if (trimmed.isNotBlank()) {
                                                                val parts = trimmed.split("|", limit = 2)
                                                                if (parts.size == 2) {
                                                                    options.add(SelectOption(parts[0].trim(), parts[1].trim()))
                                                                } else {
                                                                    options.add(SelectOption(trimmed, trimmed))
                                                                }
                                                            }
                                                        }
                                                    } else {
                                                        // 纯管道分隔
                                                        optStr.split("|").forEach { v ->
                                                            val trimmed = v.trim()
                                                            if (trimmed.isNotBlank()) options.add(SelectOption(trimmed, trimmed))
                                                        }
                                                    }
                                                }
                                            }
                                            val displayVal = options.find { it.value == currentVal }?.label
                                                ?: options.find { it.value == default }?.label
                                                ?: currentVal.ifEmpty { default }
                                            var expanded by remember { mutableStateOf(false) }

                                            ExposedDropdownMenuBox(
                                                expanded = expanded,
                                                onExpandedChange = { expanded = it },
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp)
                                            ) {
                                                OutlinedTextField(
                                                    value = displayVal,
                                                    onValueChange = {},
                                                    readOnly = true,
                                                    label = { Text(label) },
                                                    trailingIcon = {
                                                        ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded)
                                                    },
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .menuAnchor()
                                                )
                                                ExposedDropdownMenu(
                                                    expanded = expanded,
                                                    onDismissRequest = { expanded = false }
                                                ) {
                                                    options.forEach { opt ->
                                                        DropdownMenuItem(
                                                            text = { Text(opt.label) },
                                                            onClick = {
                                                                viewModel.setSettingValue(key, opt.value)
                                                                expanded = false
                                                            }
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                        "slider" -> {
                                            val min = setting.optDouble("min", 0.0).toFloat()
                                            val max = setting.optDouble("max", 100.0).toFloat()
                                            val currentFloat = currentVal.toFloatOrNull() ?: default.toFloatOrNull() ?: min

                                            Text(label, style = MaterialTheme.typography.bodySmall,
                                                modifier = Modifier.padding(top = 8.dp))
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Slider(
                                                    value = currentFloat,
                                                    onValueChange = { viewModel.setSettingValue(key, it.toString()) },
                                                    valueRange = min..max,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Text(
                                                    "%.1f".format(currentFloat),
                                                    style = MaterialTheme.typography.bodySmall,
                                                    modifier = Modifier.padding(start = 8.dp)
                                                )
                                            }
                                        }
                                        else -> {
                                            // Default: string
                                            OutlinedTextField(
                                                value = currentVal,
                                                onValueChange = { viewModel.setSettingValue(key, it) },
                                                label = { Text(label) },
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // 日志 tab
                        Column(modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
                            if (moduleLogs.isEmpty()) {
                                Text("暂无该模块的日志", style = MaterialTheme.typography.bodyMedium)
                            } else {
                                Text("共 ${moduleLogs.size} 条日志",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(vertical = 4.dp))
                                moduleLogs.forEach { logLine ->
                                    Text(
                                        logLine,
                                        style = MaterialTheme.typography.bodySmall,
                                        fontFamily = FontFamily.Monospace,
                                        modifier = Modifier.padding(vertical = 2.dp)
                                    )
                                }
                            }
                        }
                    }
                }
            },
            confirmButton = {
                Row {
                    TextButton(onClick = { viewModel.closePackageSettings() }) { Text("关闭") }
                    if (packageSettings.isNotEmpty()) {
                        TextButton(onClick = { viewModel.saveSettings() }) {
                            Icon(Icons.Outlined.Save, contentDescription = null)
                            Text(" 保存")
                        }
                    }
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
