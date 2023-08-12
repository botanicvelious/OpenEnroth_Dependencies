#!/bin/bash

# Parse args.
if [[ "$1" = "-h" ]]; then
    echo "Usage: $(basename "$0") [-jTHREADS] BUILD_TYPE BUILD_ARCH REPOS_DIR TARGET_ZIP"
    exit 1
fi

THREADS_ARG=
if [[ "$1" = -j* ]]; then
    THREADS_ARG="$1"
    shift 1
fi

if [[ "$#" != 4 ]]; then
    echo "Four arguments required. Use -h for help."
    exit 1
fi

BUILD_TYPE="$1"
BUILD_ARCH="$2"
REPOS_DIR="$3"
TARGET_ZIP="$4"

# Echo on - for debugging.
set -x

# Set up dir vars.
TMP_DIR="./tmp"
BUILD_DIR="$TMP_DIR/build"
INSTALL_DIR="$TMP_DIR/install"

# SDL install requires absolute paths for some reason.
function make_absolute() {
    if [[ "$1" = /* ]]; then
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
rm "$TARGET_ZIP"

# Figure out additional args.
ADDITIONAL_CMAKE_ARGS=()
ADDITIONAL_FFMPEG_ARGS=()
ADDITIONAL_MAKE_ARGS_STRING="$THREADS_ARG"
if [[ "$OSTYPE" = darwin* ]]; then
    # Deployment target is in sync with what's set in the main OE repo in the root CMakeLists.txt.
    export MACOSX_DEPLOYMENT_TARGET="11"
    if [[ "$BUILD_ARCH" = x86_64 ]]; then
        export MACOSX_DEPLOYMENT_TARGET="10.15"
    fi

    ADDITIONAL_FFMPEG_ARGS=(
        "--arch=$BUILD_ARCH"
        "--extra-cflags=-arch $BUILD_ARCH"
        "--extra-cxxflags=-arch $BUILD_ARCH"
        "--extra-ldflags=-arch $BUILD_ARCH"
    )
    ADDITIONAL_CMAKE_ARGS=(
        "-DCMAKE_OSX_ARCHITECTURES=$BUILD_ARCH"
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$OSX_DEPLOYMENT_TARGET"
    )
fi

#if [[ "$BUILD_TYPE" = "Debug" ]]; then
#    # TODO: this is where we set /MTd for windows
#    # --extra-cflags="-MTd" extra-cxxflags="-MTd" --extra-ldflags="-nodefaultlib:LIBCMT"
#fi

function cmake_install() {
    local BUILD_TYPE="$1"
    local SOURCE_DIR="$2"
    local BUILD_DIR="$3"
    local INSTALL_DIR="$4"
    local NINJA_ARGS_STRING="$5"
    shift 5 # The rest are cmake args

    cmake \
        -S "$SOURCE_DIR" \
        -B "$BUILD_DIR" \
        -G "Ninja" \
        "-DCMAKE_BUILD_TYPE=$BUILD_TYPE" \
        "-DCMAKE_INSTALL_PREFIX:PATH=$INSTALL_DIR" \
        "$@"

    # $NINJA_ARGS_STRING will glob, this is intentional.
    ninja \
        -C "$BUILD_DIR" \
        $NINJA_ARGS_STRING \
        install
}

function ffmpeg_install() {
    # Note: we build ffmpeg in release even when debug build is requested.
    local SOURCE_DIR="$1"
    local BUILD_DIR="$2"
    local INSTALL_DIR="$3"
    local MAKE_ARGS_STRING="$4"
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
        "--disable-runtime-cpudetect" \
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
        "--enable-avcodec" \
        "--enable-avformat" \
        "--enable-avutil" \
        "--enable-swresample" \
        "--enable-swscale" \
        "--enable-postproc" \
        "--enable-avfilter" \
        "--enable-dct" \
        "--enable-mdct" \
        "--enable-rdft" \
        "--enable-fft" \
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

    # $MAKE_ARGS_STRING will glob, this is intentional.
    make \
        -C "$BUILD_DIR" \
        $MAKE_ARGS_STRING \
        install
}

git -C "$REPOS_DIR" submodule update --init

ffmpeg_install \
    "$REPOS_DIR/ffmpeg" \
    "$BUILD_DIR/ffmpeg" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_MAKE_ARGS_STRING" \
    "${ADDITIONAL_FFMPEG_ARGS[@]}"

# zlib builds both shared & static
cmake_install \
    "$BUILD_TYPE" \
    "$REPOS_DIR/zlib" \
    "$BUILD_DIR/zlib" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_MAKE_ARGS_STRING" \
    "${ADDITIONAL_CMAKE_ARGS[@]}" \
    "-DCMAKE_DEBUG_POSTFIX=d" # This is needed for non-config find_package to work.

cmake_install \
    "$BUILD_TYPE" \
    "$REPOS_DIR/openal_soft" \
    "$BUILD_DIR/openal_soft" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_MAKE_ARGS_STRING" \
    "${ADDITIONAL_CMAKE_ARGS[@]}" \
    "-DLIBTYPE=STATIC" \
    "-DALSOFT_UTILS=OFF" \
    "-DALSOFT_EXAMPLES=OFF" \
    "-DALSOFT_TESTS=OFF"

cmake_install \
    "$BUILD_TYPE" \
    "$REPOS_DIR/sdl" \
    "$BUILD_DIR/sdl" \
    "$INSTALL_DIR" \
    "$ADDITIONAL_MAKE_ARGS_STRING" \
    "${ADDITIONAL_CMAKE_ARGS[@]}" \
    "-DSDL_STATIC=ON" \
    "-DSDL_SHARED=OFF" \
    "-DSDL_TEST=OFF"

# We don't need docs & executables.
rm -rf "$INSTALL_DIR/share"
rm -rf "$INSTALL_DIR/bin"

# We don't want unneeded path in the zip archive, and there is no other way to do it except with pushd/popd:
# https://superuser.com/questions/119649/avoid-unwanted-path-in-zip-file/119661#119661
pushd "$INSTALL_DIR"
zip -r "$TARGET_ZIP" ./*
popd
