# shared_preferences_android 2.5.x uses JNI to load these Kotlin types and
# method descriptors by name. R8 must preserve both their names and members.
# Without this, SharedPreferences.getInstance() fails before the first frame
# in release builds, despite debug builds and widget tests passing.
# Upstream fix: https://github.com/flutter/packages/pull/13311
# Keep this fallback until the minimum supported plugin/JNI version ships it.
-keep class kotlin.Unit { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt { *; }
