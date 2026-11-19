#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/build/remotaisync}"

cd "$ROOT_DIR"
dart pub get
mkdir -p "$(dirname "$OUTPUT_PATH")"
dart compile exe host/bin/remotaisync_host.dart -o "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"
printf 'Built RemoteAISync runtime: %s\n' "$OUTPUT_PATH"
