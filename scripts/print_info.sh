#!/bin/bash

# Echo on
set -x

# Should display a built zip file.
ls -lh

# List installation folder.
find ./tmp/install

# List .lib directives
# if [[ "$OSTYPE" = msys* ]]; then
#     pushd ./tmp/install/lib
#     for FILE_NAME in *.lib; do
#         dumpbin -headers -directives "$FILE_NAME"
#     done
#     popd
# fi

# Show what went wrong in ffmpeg build.
# cat ./tmp/build/ffmpeg/ffbuild/config.log
