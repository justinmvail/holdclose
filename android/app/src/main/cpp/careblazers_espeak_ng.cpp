// BUILD_SPEC.md Phase 10.3 — JNI bridge for espeak-ng on Android.
//
// Mirror of ios/Runner/TTSBridge.swift's #if CAREBLAZERS_HAS_ESPEAK_NG
// branch: same `espeak_Initialize` / `espeak_TextToPhonemes` /
// `espeak_Terminate` API, same upstream commit
// (4870adfa25b1a32b4361592f1be8a40337c58d6c, tag 1.52.0), same phoneme
// IDs out — so the Piper Amy model receives the identical token
// sequence on both platforms.
//
// __has_include guards mirror the bridging header. When
// tools/vendor_espeak_ng.sh hasn't dropped sources under
// android/app/src/main/cpp/espeak-ng/, the espeak headers are absent
// and every native call here returns -1 / null / false. The Kotlin
// side reads `nativeHasEspeakNG()` once at process start and falls
// through to the Phase 9.4 character-lookup phonemizer if it returns
// false.

#include <jni.h>
#include <string>

#if __has_include(<espeak-ng/espeak_ng.h>)
#include <espeak-ng/espeak_ng.h>
#include <espeak-ng/speak_lib.h>
#define CAREBLAZERS_HAS_ESPEAK_NG 1
#else
#define CAREBLAZERS_HAS_ESPEAK_NG 0
#endif

extern "C" {

// `EspeakNGNative` is a Kotlin `object`, so native methods bind as
// instance methods on the singleton; the second JNI argument is the
// INSTANCE jobject (unused here).

JNIEXPORT jboolean JNICALL
Java_com_careblazers_careblazers_EspeakNGNative_nativeHasEspeakNG(
    JNIEnv* /* env */, jobject /* thiz */) {
#if CAREBLAZERS_HAS_ESPEAK_NG
    return JNI_TRUE;
#else
    return JNI_FALSE;
#endif
}

// Returns the sample rate reported by espeak_Initialize on success
// (>0), or a negative value on failure:
//   -1  espeak-ng not linked (vendor script not run)
//   -2  espeak_Initialize returned non-positive rate (bad data path)
//   -3  espeak_SetVoiceByName("en-us") failed (voicedata missing)
JNIEXPORT jint JNICALL
Java_com_careblazers_careblazers_EspeakNGNative_nativeInitialize(
    JNIEnv* env, jobject /* thiz */, jstring jPath) {
#if CAREBLAZERS_HAS_ESPEAK_NG
    if (jPath == nullptr) return -2;
    const char* path = env->GetStringUTFChars(jPath, nullptr);
    if (path == nullptr) return -2;
    // AUDIO_OUTPUT_SYNCHRONOUS=2 keeps espeak from spinning up its own
    // playback thread; we only use the text-to-phonemes API and
    // AudioTrack handles the audio. Buflength=0 = library default,
    // options=0 = no library-side debug flags.
    int rate = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, path, 0);
    env->ReleaseStringUTFChars(jPath, path);
    if (rate <= 0) return -2;
    if (espeak_SetVoiceByName("en-us") != EE_OK) return -3;
    return static_cast<jint>(rate);
#else
    (void)env; (void)jPath;
    return -1;
#endif
}

// Returns the IPA-phoneme string for `jText`, or null on failure /
// when espeak-ng isn't linked. The caller passes UTF-8 English text;
// the JNI string conversion is UTF-8 -> Modified UTF-8 -> UTF-8, but
// since the input is plain ASCII for English caregiver scripts the
// round-trip is identity in practice.
JNIEXPORT jstring JNICALL
Java_com_careblazers_careblazers_EspeakNGNative_nativeTextToPhonemes(
    JNIEnv* env, jobject /* thiz */, jstring jText) {
#if CAREBLAZERS_HAS_ESPEAK_NG
    if (jText == nullptr) return nullptr;
    const char* text = env->GetStringUTFChars(jText, nullptr);
    if (text == nullptr) return nullptr;

    // espeak_TextToPhonemes advances a `const void **` cursor through
    // the input until the trailing NUL. Multi-sentence scripts
    // (decoder copy commonly spans two or three) need a loop, mirroring
    // the iOS TTSBridge.swift `espeakIPA` helper.
    std::string aggregated;
    const void* cursor = static_cast<const void*>(text);
    while (cursor != nullptr) {
        const char* tip = static_cast<const char*>(cursor);
        if (*tip == '\0') break;
        // phonememode 0x02 = IPA (Unicode) output, no separator char.
        // textmode (espeakCHARS_UTF8) is the input encoding.
        const char* result = espeak_TextToPhonemes(
            &cursor, espeakCHARS_UTF8, 0x02);
        if (result == nullptr) break;
        aggregated.append(result);
    }

    env->ReleaseStringUTFChars(jText, text);
    return env->NewStringUTF(aggregated.c_str());
#else
    (void)env; (void)jText;
    return nullptr;
#endif
}

JNIEXPORT void JNICALL
Java_com_careblazers_careblazers_EspeakNGNative_nativeTerminate(
    JNIEnv* /* env */, jobject /* thiz */) {
#if CAREBLAZERS_HAS_ESPEAK_NG
    espeak_Terminate();
#endif
}

} // extern "C"
