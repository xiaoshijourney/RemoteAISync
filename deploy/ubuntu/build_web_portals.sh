#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_root="${1:-$repo_root/dist/web}"

cd "$repo_root"
flutter build web --release --base-href /app/ --output "$output_root/app"

cd "$repo_root/release_portal"
flutter pub get
flutter build web --release --base-href /manage/ --output "$output_root/manage"

printf 'Built client: %s/app\nBuilt manager: %s/manage\n' "$output_root" "$output_root"
