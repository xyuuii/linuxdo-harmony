#!/bin/sh
set -eu
probe_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$probe_root/../.." && pwd)
export ECH_OHOS_SDK_ROOT=${ECH_OHOS_SDK_ROOT:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}
export OHOS_SDK_NATIVE="$ECH_OHOS_SDK_ROOT"
export PATH="$ECH_OHOS_SDK_ROOT/build-tools/cmake/bin:$ECH_OHOS_SDK_ROOT/llvm/bin:$PATH"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$probe_root/ohos-clang.sh"
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$project_root/artifacts/ech-native-20261018/cargo-target"}
exec cargo build --locked --manifest-path "$probe_root/Cargo.toml" --target aarch64-unknown-linux-ohos --release "$@"
