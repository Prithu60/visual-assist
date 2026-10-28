# =============================================================================
# TensorFlow Lite - reflection-heavy, crashes at runtime if minified
# =============================================================================
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-keep class org.tensorflow.lite.nnapi.** { *; }
-keepclassmembers class org.tensorflow.lite.** { native <methods>; }
-dontwarn org.tensorflow.lite.**

# =============================================================================
# Flutter plugin machinery
# =============================================================================
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }

# =============================================================================
# Google Play Core (deferred components) - we don't use this, suppress warnings
# This is the fix for your R8 "Missing class com.google.android.play.core.*" errors
# =============================================================================
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
-keep interface com.google.android.play.core.** { *; }

# =============================================================================
# flutter_tts
# =============================================================================
-keep class com.tundralabs.fluttertts.** { *; }

# =============================================================================
# Camera2 API (used by our MethodChannel)
# =============================================================================
-keep class android.hardware.camera2.** { *; }

# =============================================================================
# Preserve annotations and signatures for reflection
# =============================================================================
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod