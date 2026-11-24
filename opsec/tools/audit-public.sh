#!/bin/bash

set -euo pipefail
umask 077

ROOT="${1:-}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "usage: $0 PUBLIC_TREE" >&2; exit 1; }
ROOT="$(realpath "$ROOT")"
deny='carbon|oraculo|desktop-[0-9a-f]{4}|192\.168\.1\.|100\.71\.|forgejo|Cobra/|matrix\.example|room[_-]?id|DEVTRACK|Infisical|attk-box-setup|redteam|Tactical Red Team'
tor_deny='^TOR_BLACKLIST="[a-z]|^TOR_CIRCUIT_ROTATION="(15|30)"|^MaxCircuitDirtiness[[:space:]]+[0-9]+|^NumEntryGuards[[:space:]]+[0-9]+|^ConnectionPadding[[:space:]]+[01]'

scan_tree() {
    local tree="$1"
    if find "$tree" -type l -print -quit | grep -q .; then
        echo "public audit: symlink detected" >&2
        return 1
    fi
    while IFS= read -r -d '' file; do
        mime=$(file -b --mime-type "$file")
        case "$mime" in text/*|application/json|application/xml|application/x-shellscript|inode/x-empty) ;;
            *) echo "public audit: non-text artifact rejected: ${file#$tree/} ($mime)" >&2; return 1 ;;
        esac
    done < <(find "$tree" -path "$tree/.git" -prune -o -type f -print0)
    if rg --text -n -i "$deny" "$tree" --glob '!.git/**' --glob '!SOURCE-MANIFEST.sha256' \
        --glob '!**/test-public-defaults.sh' --glob '!**/audit-public.sh'; then
        echo "public audit: private marker detected" >&2
        return 1
    fi
    if rg --text -n "$tor_deny" "$tree/opsec/configs" "$tree/opsec/lib" "$tree/opsec/scripts"; then
        echo "public audit: distinguishing Tor default detected" >&2
        return 1
    fi
    [ "$(grep -Fxc 'Copyright (c) 2026 n0mad1k' "$tree/LICENSE")" -eq 1 ] || {
        echo "public audit: approved rights-holder attribution is missing or changed" >&2; return 1;
    }
    [ "$(grep -Fxc 'Ghost Protocol OPSEC is Copyright (c) 2026 n0mad1k and is distributed under the MIT License.' "$tree/NOTICE.md")" -eq 1 ] || {
        echo "public audit: approved NOTICE attribution is missing or changed" >&2; return 1;
    }
}

scan_tree "$ROOT"
"$ROOT/opsec/tests/test-public-defaults.sh"
"$ROOT/opsec/tests/test-opsec-browser-static.sh"
"$ROOT/opsec/tests/test-installer-contract.sh"
"$ROOT/opsec/tests/test-config-validation.sh"

command -v gitleaks >/dev/null 2>&1 || { echo "public audit: gitleaks is required" >&2; exit 1; }
gitleaks dir "$ROOT" --no-banner --redact --exit-code 1
(
    cd "$ROOT"
    sha256sum -c SOURCE-MANIFEST.sha256 >/dev/null
)

# Build and audit the exact one-commit, clean-history repository that is fit
# for publication. No private repository objects are copied into this root.
if [ ! -d "$ROOT/.git" ]; then
    git -C "$ROOT" init -q -b main
    git -C "$ROOT" config user.name n0mad1k
    git -C "$ROOT" config user.email n0mad1k@users.noreply.github.com
    git -C "$ROOT" add --all
    git -C "$ROOT" commit -q -m 'Publish Ghost Protocol OPSEC'
fi
[ "$(git -C "$ROOT" rev-list --all --count)" -eq 1 ] || { echo "public audit: history is not a single clean commit" >&2; exit 1; }
[ -z "$(git -C "$ROOT" fsck --full --no-reflogs --unreachable 2>/dev/null)" ] || { echo "public audit: unreachable Git objects found" >&2; exit 1; }
if git -C "$ROOT" grep -I -n -i -E "$deny" "$(git -C "$ROOT" rev-list --all)" -- \
    ':!opsec/tests/test-public-defaults.sh' ':!opsec/tools/audit-public.sh'; then
    echo "public audit: private marker found in Git objects" >&2
    exit 1
fi

scratch="$(mktemp -d)"
trap 'chmod -R u+w "$scratch" 2>/dev/null || true; rm -rf -- "$scratch"' EXIT
git -C "$ROOT" archive --format=tar HEAD > "$scratch/release.tar"
tar -tf "$scratch/release.tar" > "$scratch/archive.list"
if grep -E '(^|/)\.git/|(^|/)\.workflow-|(^|/)\.active-item' "$scratch/archive.list"; then
    echo "public audit: private workflow artifact in release archive" >&2
    exit 1
fi
git clone -q --no-local "$ROOT" "$scratch/fresh-clone"
scan_tree "$scratch/fresh-clone"
gitleaks git "$scratch/fresh-clone" --no-banner --redact --exit-code 1
git -C "$scratch/fresh-clone" fsck --full --strict >/dev/null
printf 'PASS: public tree, Git objects, archive, and fresh clone audit\n'
