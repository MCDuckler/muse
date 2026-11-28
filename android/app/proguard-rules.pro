# kotlinx.serialization keeps its generated serializers through its own rules; the
# models are reached reflectively only through those.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keep,includedescriptorclasses class dance.duckduck.wetowl.**$$serializer { *; }
-keepclassmembers class dance.duckduck.wetowl.** { *** Companion; }
-keepclasseswithmembers class dance.duckduck.wetowl.** { kotlinx.serialization.KSerializer serializer(...); }
