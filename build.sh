#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
hidapi_prefix=$(brew --prefix hidapi)
app_dir="$script_dir/REAI Music Controller.app"
app_contents="$app_dir/Contents"
app_macos="$app_contents/MacOS"
app_resources="$app_contents/Resources"
signing_identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
fi

mkdir -p "$app_macos" "$app_resources"
install -m 0644 "$script_dir/Info.plist" "$app_contents/Info.plist"
install -m 0644 "$script_dir/assets/lovstudio-logo.svg" "$app_resources/lovstudio-logo.svg"
clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -fobjc-arc \
  -O2 \
  -framework Cocoa \
  -framework CoreBluetooth \
  -framework IOKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework QuartzCore \
  -framework SceneKit \
  -framework Security \
  -framework Speech \
  -F/System/Library/PrivateFrameworks \
  -framework MediaRemote \
  -I"$hidapi_prefix/include/hidapi" \
  -L"$hidapi_prefix/lib" \
  -Wl,-rpath,"$hidapi_prefix/lib" \
  -lhidapi \
  "$script_dir/reai-bluetooth-bridge.m" \
  "$script_dir/reai-mode-ui.m" \
  "$script_dir/reai-voice-companion.m" \
  "$script_dir/reai-music-controller.m" \
  -o "$app_macos/reai-music-controller"

codesign --force --deep --sign "$signing_identity" --timestamp=none "$app_dir"
clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  -framework CoreAudio \
  -framework AudioToolbox \
  -I"$hidapi_prefix/include/hidapi" \
  -L"$hidapi_prefix/lib" \
  -Wl,-rpath,"$hidapi_prefix/lib" \
  -lhidapi \
  "$script_dir/reai-volume-controller.c" \
  -o "$script_dir/reai-volume-controller"

codesign --force --sign - "$script_dir/reai-volume-controller"
clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  -I"$hidapi_prefix/include/hidapi" \
  -L"$hidapi_prefix/lib" \
  -Wl,-rpath,"$hidapi_prefix/lib" \
  -lhidapi \
  "$script_dir/reai-key-config.c" \
  -o "$script_dir/reai-key-config"

codesign --force --sign - "$script_dir/reai-key-config"
echo "Built: $app_dir"
echo "Built: $script_dir/reai-volume-controller"
echo "Built: $script_dir/reai-key-config"
