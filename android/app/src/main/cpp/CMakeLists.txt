# BUILD_SPEC.md Phase 10.3 — JNI build for libcareblazers_espeak_ng.so.
#
# Mirror of ios/Vendored/espeak-ng/espeak-ng.podspec. The C sources +
# headers under cpp/espeak-ng/ are populated by
# tools/vendor_espeak_ng.sh; until that script runs they're absent and
# the `file(GLOB ...)` below resolves to an empty list. The JNI shim
# (careblazers_espeak_ng.cpp) keeps `__has_include` guards around every
# espeak symbol, so the library still compiles + ships in the APK on a
# fresh checkout — it just signals "unavailable" through
# `nativeHasEspeakNG()` and the Kotlin layer falls back to the Phase 9.4
# character-lookup phonemizer. Same contract as the iOS bridging
# header's `__has_include(<espeak-ng/espeak_ng.h>)`.

cmake_minimum_required(VERSION 3.18.1)
project(careblazers_espeak_ng LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ESPEAK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/espeak-ng")
file(GLOB ESPEAK_SOURCES CONFIGURE_DEPENDS "${ESPEAK_DIR}/libespeak-ng/*.c")

if(ESPEAK_SOURCES)
    message(STATUS "careblazers: espeak-ng sources present — JNI bridge will link the real library")
    # Same flag set Home Assistant's iOS voice library uses, mirrored
    # from ios/Vendored/espeak-ng/espeak-ng.podspec. USE_ASYNC=0 keeps
    # espeak from spinning up its own playback thread (we drive
    # AudioTrack ourselves). HAVE_PCAUDIOLIB_AUDIO_H=0 because Android
    # ships no libpcaudio. PACKAGE_VERSION + PATH_ESPEAK_DATA are
    # normally written by autoconf into config.h; we skip that step
    # and bake them in here.
    add_definitions(
        -DUSE_ASYNC=0
        -DHAVE_PCAUDIOLIB_AUDIO_H=0
        -DPACKAGE_VERSION="1.52.0"
        -DPATH_ESPEAK_DATA="espeak-ng-data"
    )
    include_directories(
        "${ESPEAK_DIR}/include"
        "${ESPEAK_DIR}/libespeak-ng"
    )
else()
    message(STATUS "careblazers: espeak-ng sources absent — JNI bridge will signal unavailable until tools/vendor_espeak_ng.sh runs")
endif()

add_library(careblazers_espeak_ng SHARED
    careblazers_espeak_ng.cpp
    ${ESPEAK_SOURCES}
)

# espeak-ng's C sources lean on a few ancient-spelling warnings. Quiet
# them so the build log stays readable; none mask real bugs (mirror of
# the iOS podspec's -Wno set).
if(ESPEAK_SOURCES)
    target_compile_options(careblazers_espeak_ng PRIVATE
        -Wno-unused-parameter
        -Wno-unused-but-set-variable
        -Wno-shorten-64-to-32
        -Wno-format
    )
endif()

find_library(log-lib log)
target_link_libraries(careblazers_espeak_ng ${log-lib})
