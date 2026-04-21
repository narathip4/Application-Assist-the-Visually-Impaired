#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-aab}"
VLM_BASE_URL_ARG="${2:-}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_PROPS="$PROJECT_ROOT/android/key.properties"
DEFAULT_VLM_BASE_URL="https://narathip7-fastvlm-space-test.hf.space"

if [[ -n "${VLM_BASE_URL:-}" ]]; then
  EFFECTIVE_VLM_BASE_URL="$VLM_BASE_URL"
elif [[ -n "$VLM_BASE_URL_ARG" ]]; then
  EFFECTIVE_VLM_BASE_URL="$VLM_BASE_URL_ARG"
else
  EFFECTIVE_VLM_BASE_URL="$DEFAULT_VLM_BASE_URL"
fi

if [[ ! -f "$KEY_PROPS" ]]; then
  echo "Missing android/key.properties"
  exit 1
fi

if grep -q "replace-with-your-" "$KEY_PROPS"; then
  echo "android/key.properties still contains placeholder values."
  echo "Open the file and replace the passwords before building."
  exit 1
fi

echo "Using VLM_BASE_URL=$EFFECTIVE_VLM_BASE_URL"

case "$MODE" in
  apk)
    exec flutter build apk --release --dart-define="VLM_BASE_URL=$EFFECTIVE_VLM_BASE_URL"
    ;;
  aab)
    exec flutter build appbundle --release --dart-define="VLM_BASE_URL=$EFFECTIVE_VLM_BASE_URL"
    ;;
  apk-split)
    exec flutter build apk --release --split-per-abi --dart-define="VLM_BASE_URL=$EFFECTIVE_VLM_BASE_URL"
    ;;
  *)
    echo "Usage: bash scripts/build_android_release.sh [aab|apk|apk-split] [vlm_base_url]"
    exit 1
    ;;
esac
