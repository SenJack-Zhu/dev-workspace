package com.mozhi.reader.modules

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Module package metadata, parsed from `manifest.json` inside a .mrm archive.
 *
 * A .mrm (MoRead Module) file is a standard ZIP archive containing:
 * ```
 * my-module.mrm (ZIP)
 *   ├── manifest.json    — this metadata (required)
 *   ├── *.js             — one or more JavaScript module files (at least one required)
 *   ├── config.json      — optional, key-value pairs merged into shared config
 *   └── lib/             — optional, additional resources accessible to the module
 * ```
 *
 * If manifest.json is missing, the package name defaults to the archive filename.
 */
@Serializable
data class ModulePackageInfo(
    /** Unique package name, used as the subdirectory name. */
    @SerialName("name") val name: String,
    /** Human-readable display name. */
    @SerialName("displayName") val displayName: String = name,
    /** Semantic version string (e.g. "1.0.0"). */
    @SerialName("version") val version: String = "1.0.0",
    /** Author name. */
    @SerialName("author") val author: String = "",
    /** Short description of what the module does. */
    @SerialName("description") val description: String = "",
    /** Minimum MoRead version required (optional). */
    @SerialName("minAppVersion") val minAppVersion: String = "",
    /** List of hook events this module intends to register (for documentation only). */
    @SerialName("hooks") val hooks: List<String> = emptyList(),
    /** Whether to overwrite existing package on re-import (default: true). */
    @SerialName("overwrite") val overwrite: Boolean = true
)
