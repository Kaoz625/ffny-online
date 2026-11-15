#!/bin/bash
# Build Def Jam: Fight for NY (recomp) for iPhone/iPad, arm64 device. blz/ios branch.
# Needs: src/recomp/gen from the Mac pipeline (your own dump), ~/defjam-src/ios-deps (build-deps.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
DEPS=${DEFJAM_IOS_DEPS:-$HOME/defjam-src/ios-deps}
MVK=$DEPS/MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a
VKINC=${VULKAN_INCLUDE:-/opt/homebrew/include}
# The toolkit (submodule) needs two small iOS fixes; apply them once.
if git -C tools/xboxrecomp apply --check ../../ios/patches/xboxrecomp-ios.patch 2>/dev/null; then
  git -C tools/xboxrecomp apply ../../ios/patches/xboxrecomp-ios.patch
fi
cmake -S . -B build/ios -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_PREFIX_PATH="$DEPS/prefix" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DVulkan_INCLUDE_DIR="$VKINC" -DVulkan_LIBRARY="$MVK" \
  -DOPENSSL_ROOT_DIR="$DEPS/prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DSHADERC_LIBRARY="$DEPS/prefix/lib/libshaderc_combined.a" -DSHADERC_INCLUDE_DIR="$DEPS/prefix/include" \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DDEFJAM_BUILD_APP=OFF
cmake --build build/ios
