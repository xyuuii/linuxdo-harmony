#!/bin/sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root/app"
if [ ! -f build-profile.json5 ]; then
  cp build-profile.example.json5 build-profile.json5
fi
exec devecocli build "$@"
