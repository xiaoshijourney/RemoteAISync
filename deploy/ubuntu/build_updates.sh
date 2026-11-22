#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${1:-$repo_root/dist/linux}"
mkdir -p "$output_dir"
cd "$repo_root"
dart pub get
dart compile exe host/bin/remotaisync_updates.dart -o "$output_dir/remotaisync-updates"
printf 'Built %s\n' "$output_dir/remotaisync-updates"
