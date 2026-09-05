# Tink 在 androidx.security-crypto 中引用的 Error Prone 类型全是源码级注解，运行时
# 不参与密钥处理；依赖 POM 未把它们带进 APK，R8 需要显式知道可以安全忽略。
-dontwarn com.google.errorprone.annotations.CanIgnoreReturnValue
-dontwarn com.google.errorprone.annotations.CheckReturnValue
-dontwarn com.google.errorprone.annotations.Immutable
-dontwarn com.google.errorprone.annotations.RestrictedApi

# ── Rhino JS engine (module system) ────────────────────────────
# Keep all Rhino classes; R8's aggressive shrinking breaks the dynamic
# class loading and reflection that Rhino relies on.
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.classfile.** { *; }
-dontwarn org.mozilla.**
-dontwarn org.mozilla.javascript.**

# Keep the module system API classes; they are accessed via reflection
# from the JS bridge and must not be renamed or have members removed.
-keep class com.mozhi.reader.modules.** { *; }
-keepclassmembers class com.mozhi.reader.modules.ModuleApi { *; }

