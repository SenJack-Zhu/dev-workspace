package com.mozhi.reader.modules

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module that provides the JS engine and module system singletons.
 *
 * HookRegistry and ModuleApi are already @Singleton @Inject classes
 * (Hilt auto-provides them). This module provides JsEngine, ModuleLoader
 * and ModuleImporter which need constructor injection of the other singletons.
 */
@Module
@InstallIn(SingletonComponent::class)
object ModuleModule {

    @Provides
    @Singleton
    fun provideJsEngine(
        @ApplicationContext context: android.content.Context,
        hookRegistry: HookRegistry,
        moduleApi: ModuleApi
    ): JsEngine = JsEngine(context, hookRegistry, moduleApi)

    @Provides
    @Singleton
    fun provideModuleLoader(
        @ApplicationContext context: android.content.Context,
        jsEngine: JsEngine,
        hookRegistry: HookRegistry
    ): ModuleLoader = ModuleLoader(context, jsEngine, hookRegistry)

    @Provides
    @Singleton
    fun provideModuleImporter(
        @ApplicationContext context: android.content.Context,
        hookRegistry: HookRegistry
    ): ModuleImporter = ModuleImporter(context, hookRegistry)
}
