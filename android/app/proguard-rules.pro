# Holdclose R8/ProGuard keep rules.
#
# Why this file exists: alpha testers on Android release builds hit a hard
# crash that froze appointment/medication saves (fb 2026-06-14):
#   PlatformException: TypeToken must be created with a type argument …
#   When using code shrinkers (ProGuard, R8) make sure that generic
#   signatures are preserved.
# That's flutter_local_notifications' Gson usage failing because R8/D8
# (running for core-library desugaring + minification) stripped the
# generic `Signature` attribute. The rules below preserve it and keep the
# reflection/JNI classes the bundled neural TTS relies on.

# --- Preserve generic signatures + annotations (the actual crash fix) ---
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses,EnclosingMethod

# --- flutter_local_notifications + its Gson type tokens ---
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-keep class com.google.gson.** { *; }
-dontwarn com.google.gson.**

# --- Bundled neural TTS: ONNX Runtime (JNI looks classes up by name) ---
-keep class ai.onnxruntime.** { *; }
-keep class com.microsoft.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# --- App code, incl. the espeak-ng JNI bridge (native methods are bound
#     by class + method name, so R8 must not rename them) ---
-keep class com.careblazers.careblazers.** { *; }

# --- Flutter embedding (belt-and-suspenders for reflection-based plugins;
#     most plugins ship their own consumer rules that R8 already applies) ---
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**
