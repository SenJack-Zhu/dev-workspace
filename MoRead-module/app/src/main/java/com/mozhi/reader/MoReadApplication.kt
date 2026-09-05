package com.mozhi.reader

import android.app.Application
import com.mozhi.reader.core.backup.BackupRestoreBootstrap
import com.mozhi.reader.feature.importer.BookTextMaterializeWorker
import com.mozhi.reader.modules.HookPoints
import com.mozhi.reader.modules.HookRegistry
import com.mozhi.reader.modules.ModuleLoader
import dagger.hilt.android.HiltAndroidApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltAndroidApp
class MoReadApplication : Application() {

    @Inject lateinit var hookRegistry: HookRegistry
    @Inject lateinit var moduleLoader: ModuleLoader

    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        // 待恢复包必须先于 Hilt component 创建；否则 Room/DataStore 可能已经持有旧文件句柄。
        BackupRestoreBootstrap.applyPending(this)
        super.onCreate()

        // Initialize module system: wire static accessor and load JS modules.
        HookPoints.init(hookRegistry)
        appScope.launch {
            val result = moduleLoader.loadAll()
            hookRegistry.log("[MoReadApp] Module system: ${result.message}")
        }

        // 正文补齐仍需启动兜底；向量索引改为按需（首次检索时按书触发），不再全库补扫。
        BookTextMaterializeWorker.enqueueStartup(this)
    }
}
