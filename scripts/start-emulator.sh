#!/bin/sh
set -eu
# Start an existing instance without recreating it or clearing userdata.
task_emulator_name=${1:-CodexPhone}
task_deveco_dir=${DEVECO_STUDIO_CONTENTS:-/Applications/DevEco-Studio.app/Contents}
task_image_root=${HARMONY_SYSTEM_IMAGE_ROOT:-"$HOME/Library/Huawei/Sdk"}
task_instance_root=${HARMONY_EMULATOR_INSTANCE_ROOT:-"$HOME/.Huawei/Emulator/deployed"}
if [ ! -x "$task_deveco_dir/tools/emulator/Emulator" ]; then
  echo "Set DEVECO_STUDIO_CONTENTS to the installed DevEco Studio Contents directory." >&2
  exit 1
fi
DEVECO_SDK_HOME="$task_deveco_dir/sdk" exec "$task_deveco_dir/tools/emulator/Emulator" \
  -start "$task_emulator_name" -instancePath "$task_instance_root" -imageRoot "$task_image_root" -bootMode snapshot
