# Applied to every app that depends on this library (consumerProguardFiles).
#
# libvlc's native code (libvlcjni.so) looks up Java classes, fields and
# methods by name via JNI (event callbacks, Media/MediaPlayer/Dialog peers,
# native-backed fields). R8 renaming or stripping any of them makes those
# lookups fail at runtime — a release-only crash. The libvlc-all AAR ships no
# consumer rules of its own (no proguard.txt), so we provide them here.
-keep class org.videolan.libvlc.** { *; }
