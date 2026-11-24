#!/bin/bash

set -euo pipefail
umask 077

SOURCE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$SOURCE_ROOT/opsec/public-export.manifest"
DESTINATION="${1:-}"

die() { printf 'export-public: %s\n' "$*" >&2; exit 1; }
[ -n "$DESTINATION" ] || die "usage: $0 ABSOLUTE_NEW_DESTINATION"
[[ "$DESTINATION" = /* ]] || die "destination must be absolute"
[ ! -e "$DESTINATION" ] || die "destination already exists"

parent="$(dirname "$DESTINATION")"
[ -d "$parent" ] || die "destination parent does not exist"
stage="$(mktemp -d "$parent/.ghost-opsec-public.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT

while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    case "$relative" in /*|*..*) die "unsafe manifest entry: $relative" ;; esac
    source="$SOURCE_ROOT/$relative"
    [ -f "$source" ] && [ ! -L "$source" ] || die "manifest source is not a regular file: $relative"
    install -D -m "$(stat -c %a "$source")" "$source" "$stage/$relative"
done < "$MANIFEST"

install -m 0644 "$SOURCE_ROOT/LICENSE" "$stage/LICENSE"
install -m 0644 "$SOURCE_ROOT/opsec/README.md" "$stage/README.md"
install -m 0644 "$SOURCE_ROOT/opsec/NOTICE.md" "$stage/NOTICE.md"
printf '%s\n' '2.0.0' > "$stage/VERSION"
(
    cd "$stage"
    find . -type f ! -name SOURCE-MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > SOURCE-MANIFEST.sha256
)

"$stage/opsec/tools/audit-public.sh" "$stage"
mv -- "$stage" "$DESTINATION"
trap - EXIT
printf 'Public candidate created at %s\n' "$DESTINATION"
