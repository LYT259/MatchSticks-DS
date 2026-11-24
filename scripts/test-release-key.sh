#!/bin/bash
# Release-key rotation guard: production build must carry the current Sparkle public key and the
# migration note must explain that clients built with the previous key require one manual install.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_FILE="$HOME/.ghds-release-keys/ghds-ed25519"
PUBLIC_KEY="qQwltPD68k5anSzJBvRC+Z0xvUSfEvKbEarPKhFHyfA="
FAILURES=0
check() {
    if "$@"; then
        printf '  ✓ %s\n' "$DESCRIPTION"
    else
        printf '  ✗ %s\n' "$DESCRIPTION"
        FAILURES=$((FAILURES + 1))
    fi
}
DESCRIPTION="the production build carries the rotated Sparkle public key"
check grep -Fq "SU_PUBLIC_ED_KEY:-${PUBLIC_KEY}" scripts/build-app.sh

DESCRIPTION="the release signing key exists outside the repository with mode 0600"
if [ -f "$KEY_FILE" ] && [ "$(stat -f %Lp "$KEY_FILE")" = "600" ]; then
    printf '  ✓ %s\n' "$DESCRIPTION"
else
    printf '  ✗ %s\n' "$DESCRIPTION"
    FAILURES=$((FAILURES + 1))
fi

DESCRIPTION="the key rotation ADR records the new public key and one-time manual migration"
check grep -Fq "$PUBLIC_KEY" docs/decisions/0007-update-signing-key-rotation.md
check grep -Fq "手动安装" docs/decisions/0007-update-signing-key-rotation.md
check grep -Fq "旧版本" docs/decisions/0007-update-signing-key-rotation.md

DESCRIPTION="the release kit points to the rotation ADR instead of claiming the old key remains unchanged"
check grep -Fq "0007-update-signing-key-rotation.md" docs/release-kit.md
if grep -Fq "均沿用原值" docs/release-kit.md; then
    printf '  ✗ stale claim that SUPublicEDKey remains unchanged\n'
    FAILURES=$((FAILURES + 1))
else
    printf '  ✓ no stale claim that SUPublicEDKey remains unchanged\n'
fi

if [ "$FAILURES" -ne 0 ]; then
    printf 'release key guard: %d failures\n' "$FAILURES" >&2
    exit 1
fi
printf 'release key guard: all checks passed\n'
