#!/bin/bash

# Parse args.
if [[ "$1" == "-h" ]]; then
    echo "Usage: $(basename "$0") [-jTHREADS] BUILD_PLATFORM BUILD_ARCH BUILD_TYPE REPOS_DIR TARGET_ZIP"
    exit 1
fi

THREADS_ARG=
if [[ "$1" == -j* ]]; then
    THREADS_ARG="$1"
    shift 1
fi

if [[ "$#" != 5 ]]; then
    echo "Five arguments required. Use -h for help."
    exit 1
fi

BUILD_PLATFORM="$1"
BUILD_ARCH="$2"
BUILD_TYPE="$3"
REPOS_DIR="$4"
TARGET_ZIP="$5"

# Echo on, fail on errors, fail on undefined var usage, fail on pipeline failure.
set -euxo pipefail

# Check ANDROID_NDK.
if [[ "$BUILD_PLATFORM" == "android" && "$ANDROID_NDK" == "" ]]; then
    echo "Please provide path to your NDK via NDK environment variable!"
    exit 1
fi

# Set up dir vars.
TMP_DIR="./tmp"
BUILD_DIR="$TMP_DIR/build"
INSTALL_DIR="$TMP_DIR/install"

# SDL install requires absolute paths for some reason.
function make_absolute() {
    if [[ "$1" == /* ]]; then
        echo "$1"
    else
        echo "$(pwd)/$1"
    fi
}

REPOS_DIR="$(make_absolute "$REPOS_DIR")"
TARGET_ZIP="$(make_absolute "$TARGET_ZIP")"
BUILD_DIR="$(make_absolute "$BUILD_DIR")"
INSTALL_DIR="$(make_absolute "$INSTALL_DIR")"

# Clean up old build if it exists, we want no surprises.
rm -rf "$BUILD_DIR"
rm -rf "$INSTALL_DIR"
rm -f "$TARGET_ZIP"

# Figure out additional args.
ADDITIONAL_THREADS_ARG_STRING="$THREADS_ARG"
ADDITIONAL_CMAKE_ARGS=()
ADDITIONAL_FFMPEG_ARGS=(
    "--arch=$BUILD_ARCH"
)

# Set up default SDL build mode.
SDL_BUILD_STATIC="ON"
SDL_BUILD_SHARED="OFF"

# Set platform-specific options.
if [[ "$BUILD_PLATFORM" == "darwin" ]]; then
    # Deployment target is in sync with what's set in the main OE repo in macos.yml.
    export MACOSX_DEPLOYMENT_TARGET="11"
    if [[ "$BUILD_ARCH" == "x86_64" ]]; then
        export MACOSX_DEPLOYMENT_TARGET="10.15"
    fi

    ADDITIONAL_FFMPEG_ARGS+=(
        "--extra-cflags=-arch $BUILD_ARCH"
        "--extra-ldflags=-arch $BUILD_ARCH"
    )
    ADDITIONAL_CMAKE_ARGS+=(
        "-DCMAKE_OSX_ARCHITECTURES=$BUILD_ARCH"
    )
elif [[ "$BUILD_PLATFORM" == "windows" ]]; then
    ADDITIONAL_FFMPEG_ARGS+=(
        "--toolchain=msvc"
    )
    ADDITIONAL_CMAKE_ARGS+=(
        "-GNinja" # Use Ninja on windows. Default is MSVC project files, which are multi-config, and it's a mess.
    )

    # Note that we have to set CMAKE_(C|CXX)_FLAGS_(DEBUG|RELEASE|RELWITHDEBINFO) here and not CMAKE_(C|CXX)_FLAGS
    # because the former are appended to the latter in the compiler command line.

    if [[ "$BUILD_TYPE" == "Debug" ]]; then
        # this is where we set /MTd for ffmpeg on windows
        ADDITIONAL_FFMPEG_ARGS+=(
             "--enable-debug"
             "--extra-cflags=-MTd"
             "--extra-ldflags=-nodefaultlib:LIBCMT"
        )
        ADDITIONAL_CMAKE_ARGS+=(
            "-DCMAKE_C_FLAGS_DEBUG=-MTd -Z7 -Ob2 -Od"
            "-DCMAKE_CXX_FLAGS_DEBUG=-MTd -Z7 -Ob2 -Od"
        )
    else 
        # this is where we set /MT for ffmpeg on windows
        ADDITIONAL_FFMPEG_ARGS+=(
             "--extra-cflags=-MT"
        )
        ADDITIONAL_CMAKE_ARGS+=(
            "-DCMAKE_C_FLAGS_RELEASE=-Z7 -MT -O2 -Ob2"
            "-DCMAKE_CXX_FLAGS_RELEASE=-Z7 -MT -O2 -Ob2"
            "-DCMAKE_C_FLAGS_RELWITHDEBINFO=-Z7 -MT -O2 -Ob2"
            "-DCMAKE_CXX_FLAGS_RELWITHDEBINFO=-Z7 -MT -O2 -Ob2"
        )
    fi
elif [[ "$BUILD_PLATFORM" == "linux" ]]; then
    if [[ "$BUILD_ARCH" == "x86" ]]; then
        ADDITIONAL_CMAKE_ARGS+=(
            "-DCMAKE_CXX_FLAGS=-m32"
            "-DCMAKE_C_FLAGS=-m32"
        )
        ADDITIONAL_FFMPEG_ARGS+=(
            "--extra-cflags=-m32"
            "--extra-ldflags=-m32"
        )
    fi
elif [[ "$BUILD_PLATFORM" == "android" ]]; then
    if [[ "$BUILD_ARCH" == "arm32" ]]; then
        ANDROID_ARCH_PREFIX=armv7a-linux-androideabi
        ANDROID_ARCH_ABI=armeabi-v7a
        ADDITIONAL_FFMPEG_ARGS+=(
            "--cpu=cortex-a8"
            "--enable-neon"
            "--enable-thumb"
            "--extra-cflags=-march=armv7-a -mcpu=cortex-a8 -mfpu=vfpv3-d16 -mfloat-abi=softfp -mthumb"
            "--extra-ldflags=-Wl,--fix-cortex-a8"
        )
    elif [[ "$BUILD_ARCH" == "arm64" ]]; then
        ANDROID_ARCH_PREFIX=aarch64-linux-android
        ANDROID_ARCH_ABI=arm64-v8a
        ADDITIONAL_FFMPEG_ARGS+=(
            "--enable-neon"
        )
    elif [[ "$BUILD_ARCH" == "x86" ]]; then
        ANDROID_ARCH_PREFIX=i686-linux-android
        ANDROID_ARCH_ABI=x86
        ADDITIONAL_FFMPEG_ARGS+=(
            "--disable-asm" # Need the old gcc toolchain for x86 asm to work.
            "--extra-cflags=-march=atom -msse3 -ffast-math -mfpmath=sse"
        )
    elif [[ "$BUILD_ARCH" == "x86_64" ]]; then
        ANDROID_ARCH_PREFIX=x86_64-linux-android
        ANDROID_ARCH_ABI=x86_64
        ADDITIONAL_FFMPEG_ARGS+=(
            "--enable-x86asm"
            "--extra-cflags=-march=atom -msse3 -ffast-math -mfpmath=sse"
        )
    fi

    ANDROID_PLATFORM_VERSION=21
    ANDROID_TOOLCHAIN=${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64

    ADDITIONAL_FFMPEG_ARGS+=(
        "--disable-vulkan" # Compilation fails to find vulkan_beta.h.
        "--cross-prefix=${ANDROID_TOOLCHAIN}/bin/llvm-"
        "--cc=${ANDROID_TOOLCHAIN}/bin/${ANDROID_ARCH_PREFIX}${ANDROID_PLATFORM_VERSION}-clang"
        "--cxx=${ANDROID_TOOLCHAIN}/bin/${ANDROID_ARCH_PREFIX}${ANDROID_PLATFORM_VERSION}-clang++"
        "--target-os=linux"
        "--pkg-config=pkg-config"
        "--sysroot=${ANDROID_TOOLCHAIN}/sysroot/"
    )

    # These are derived from what gradle passes to cmake.
    # Note that args with ANDROID_ prefix are processed by the toolchain file.
    ADDITIONAL_CMAKE_ARGS+=(
        "-DCMAKE_SYSTEM_NAME=Android"
        "-DCMAKE_SYSTEM_VERSION=$ANDROID_PLATFORM_VERSION"
        "-DANDROID_PLATFORM=android-$ANDROID_PLATFORM_VERSION"
        "-DANDROID_ABI=$ANDROID_ARCH_ABI"
        "-DCMAKE_ANDROID_ARCH_ABI=$ANDROID_ARCH_ABI"
        "-DANDROID_NDK=$ANDROID_NDK"
        "-DCMAKE_ANDROID_NDK=$ANDROID_NDK"
        "-DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake"
        "-DANDROID_STL=c++_static"
    )

    # On Android we build shared SDL so that we don't have to patch SDLActivity.getLibraries, which instructs SDL
    # java runtime to load libSDL2.so first.
    SDL_BUILD_STATIC="OFF"
    SDL_BUILD_SHARED="ON"
fi

function replace_in_file() {
    local FILE_PATH="$1"
    local PATTERN="$2"
    local REPLACEMENT="$3"

    # MacOS sed doesn't have -i, so we have to copy & move.
    sed -e "s/$PATTERN/$REPLACEMENT/" "$FILE_PATH" >"$FILE_PATH.fixed"
    mv "$FILE_PATH.fixed" "$FILE_PATH"
}

function cmake_install() {
    local BUILD_TYPE="$1"
    local SOURCE_DIR="$2"
    local BUILD_DIR="$3"
    local INSTALL_DIR="$4"
    local THREADS_ARG_STRING="$5"
    shift 5 # The rest are cmake args

    cmake \
        -S "$SOURCE_DIR" \
        -B "$BUILD_DIR" \
        "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" \
        "-DCMAKE_INSTALL_PREFIX=$INSTALL_DIR" \
        "$@"

    # $THREADS_ARG_STRING will glob, this is intentional.
    cmake \
        --build "$BUILD_DIR" \
        $THREADS_ARG_STRING \
        --verbose \
        --target install
}

function ffmpeg_install() {
    # Note: we build ffmpeg in release even when debug build is requested.
    local SOURCE_DIR="$1"
    local BUILD_DIR="$2"
    local INSTALL_DIR="$3"
    local THREADS_ARG_STRING="$4"
    shift 4 # The rest are configure args

    mkdir -p "$BUILD_DIR"
    pushd "$BUILD_DIR"
    "$SOURCE_DIR/configure" \
        "--prefix=$INSTALL_DIR" \
        "--disable-everything" \
        "--disable-gpl" \
        "--disable-version3" \
        "--disable-nonfree" \
        "--enable-small" \
        "--enable-runtime-cpudetect" \
        "--disable-gray" \
        "--disable-swscale-alpha" \
        "--disable-programs" \
        "--disable-ffmpeg" \
        "--disable-ffplay" \
        "--disable-ffprobe" \
        "--disable-iconv" \
        "--disable-doc" \
        "--disable-htmlpages" \
        "--disable-manpages" \
        "--disable-podpages" \
        "--disable-txtpages" \
        "--disable-avdevice" \
        "--disable-postproc" \
        "--disable-avfilter" \
        "--disable-network" \
        "--enable-avcodec" \
        "--enable-avformat" \
        "--enable-avutil" \
        "--enable-swresample" \
        "--enable-swscale" \
        "--disable-devices" \
        "--disable-encoders" \
        "--disable-filters" \
        "--disable-hwaccels" \
        "--disable-decoders" \
        "--enable-decoder=mp3*" \
        "--enable-decoder=adpcm*" \
        "--enable-decoder=pcm*" \
        "--enable-decoder=bink" \
        "--enable-decoder=binkaudio_dct" \
        "--enable-decoder=binkaudio_rdft" \
        "--enable-decoder=smackaud" \
        "--enable-decoder=smacker" \
        "--disable-muxers" \
        "--disable-demuxers" \
        "--enable-demuxer=mp3" \
        "--enable-demuxer=bink" \
        "--enable-demuxer=binka" \
        "--enable-demuxer=smacker" \
        "--enable-demuxer=pcm*" \
        "--enable-demuxer=wav" \
        "--disable-parsers" \
        "--disable-bsfs" \
        "--disable-protocols" \
        "--enable-protocol=file" \
        "--enable-cross-compile" \
        "$@"
    popd

    # We don't want to link with bcrypt. This is windows-only, but doesn't really need an if around it.
    replace_in_file \
        "$BUILD_DIR/config.h" \
        "#define HAVE_BCRYPT [01]" \
        "#define HAVE_BCRYPT 0"
    cat "$BUILD_DIR/config.h" | grep "HAVE_BCRYPT"

    # $THREADS_ARG_STRING will glob, this is intentional.
    make \
        -C "$BUILD_DIR" \
        $THREADS_ARG_STRING \
        install V=1

    # On windows under msys we get file names is if we were on linux, and cmake find_package can't see them.
    # So we need to fix the file names. Note that .a and .lib are identical file format-wise.
    if [[ "$BUILD_PLATFORM" == "windows" ]]; then
        pushd "$INSTALL_DIR/lib"
        for FILE_NAME in *.a; do
            NEW_FILE_NAME="$FILE_NAME"
            NEW_FILE_NAME="${NEW_FILE_NAME%.a}.lib" # replace suffix: .a -> .lib.
            NEW_FILE_NAME="${NEW_FILE_NAME#lib}"    # drop "lib" prefix.
            mv "$FILE_NAME" "$NEW_FILE_NAME"
        done
        popd
    fi

    # If we do want to link with bcrypt, there is this workaround. Will it blow up if the target binary links with
    # bcrypt explicitly? I didn't check, but I'd bet it will. Commented out for now.
    # lib -nologo "-out:$INSTALL_DIR/lib/avutil_fixed.lib" bcrypt.lib "$INSTALL_DIR/lib/avutil.lib"
    # mv "$INSTALL_DIR/lib/avutil_fixed.lib" "$INSTALL_DIR/lib/avutil.lib"
}

git -C "$REPOS_DIR" submodule update --init

ffmpeg_install \
    "$REPOS_DIR/ffmpeg" \
    "$BUILD_DIR/ffmpeg" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_THREADS_ARG_STRING" \
    "${ADDITIONAL_FFMPEG_ARGS[@]}"

if [[ "$BUILD_PLATFORM" != "android" ]]; then
    # zlib builds both shared & static.
    cmake_install \
        "$BUILD_TYPE" \
        "$REPOS_DIR/zlib" \
        "$BUILD_DIR/zlib" \
        "$INSTALL_DIR" \
        "$ADDITIONAL_THREADS_ARG_STRING" \
        "${ADDITIONAL_CMAKE_ARGS[@]}" \
        "-DCMAKE_DEBUG_POSTFIX=d" # This is needed for non-config find_package to work.
fi

cmake_install \
    "$BUILD_TYPE" \
    "$REPOS_DIR/openal_soft" \
    "$BUILD_DIR/openal_soft" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_THREADS_ARG_STRING" \
    "${ADDITIONAL_CMAKE_ARGS[@]}" \
    "-DLIBTYPE=STATIC" \
    "-DALSOFT_UTILS=OFF" \
    "-DALSOFT_EXAMPLES=OFF" \
    "-DALSOFT_TESTS=OFF"

cmake_install \
    "$BUILD_TYPE" \
    "$REPOS_DIR/libpng" \
    "$BUILD_DIR/libpng" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_THREADS_ARG_STRING" \
    "${ADDITIONAL_CMAKE_ARGS[@]}" \
    "-DPNG_SHARED=OFF" \
    "-DPNG_FRAMEWORK=OFF" \
    "-DPNG_TESTS=OFF" \
    "-DPNG_TOOLS=OFF" \
    "-DZLIB_ROOT=$INSTALL_DIR" \
    "-DZLIB_USE_STATIC_LIBS=ON"

if [[ "$BUILD_PLATFORM" != "linux" ]]; then
    # Pre-building SDL on linux makes very little sense. Do we enable x11? Wayland? Something else?
    cmake_install \
        "$BUILD_TYPE" \
        "$REPOS_DIR/sdl" \
        "$BUILD_DIR/sdl" \
        "$INSTALL_DIR" \
        "$ADDITIONAL_THREADS_ARG_STRING" \
        "${ADDITIONAL_CMAKE_ARGS[@]}" \
        "-DSDL_FORCE_STATIC_VCRT=ON" \
        "-DSDL_STATIC=$SDL_BUILD_STATIC" \
        "-DSDL_SHARED=$SDL_BUILD_SHARED" \
        "-DSDL_TEST=OFF"
fi

# We don't need docs & executables.
rm -rf "$INSTALL_DIR/share"
rm -rf "$INSTALL_DIR/bin"

# We don't need dynamic zlib. Can't use proper regular expressions here b/c we need this to be portable.
# See https://stackoverflow.com/questions/39727621/a-regex-that-works-in-find.
# Note that on Windows dlls are in /bin and we've already deleted them.
find ./tmp/install "(" -regex "libz.*dylib" -or -regex "libz.*so" ")" -exec rm "{}" ";"

# And we also don't need all the symlinks.
find ./tmp/install -type l -exec rm "{}" ";"

# We don't want unneeded path in the zip archive, and there is no other way to do it except with pushd/popd:
# https://superuser.com/questions/119649/avoid-unwanted-path-in-zip-file/119661
pushd "$INSTALL_DIR"
zip -r "$TARGET_ZIP" ./*
popd
