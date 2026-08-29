#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

flutter test --no-pub --concurrency=1
tool/check_changed_dart_format.sh
dart run tool/live2d_release_gate.dart --development
dart run tool/mobile_release_gate.dart --development

if [ "${1:-}" = "--release" ]; then
  dart run tool/live2d_release_gate.dart
  dart run tool/mobile_release_gate.dart
elif [ "$#" -gt 0 ]; then
  echo "usage: tool/run_mobile_release_checks.sh [--release]" >&2
  exit 64
fi
