#!/bin/sh
set -eu
probe_sdk=${ECH_OHOS_SDK_ROOT:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}
exec "$probe_sdk/llvm/bin/clang" --target=aarch64-linux-ohos --sysroot="$probe_sdk/sysroot" -D__MUSL__ "$@"
