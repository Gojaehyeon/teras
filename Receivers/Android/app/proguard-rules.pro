# Teras receiver keeps no reflection-driven entry points beyond the Android
# framework ones AGP already preserves, so the default rules cover the app.
-dontwarn kotlinx.**

# Tink, pulled in by androidx.security-crypto, references annotations that only
# exist at compile time (Error Prone and JSR-305). They carry no behaviour, so
# R8 can drop them; without these rules it refuses to build on the missing
# references alone. This is the fix AGP itself writes to missing_rules.txt.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn javax.annotation.concurrent.**
