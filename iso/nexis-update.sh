#!/bin/bash
# NeXiS Hypervisor — Self-updater
# Downloads the latest GitHub release (.deb) and refreshes management scripts.
set -euo pipefail

REPO="santiagotoro2023/nexis-hypervisor"
API="https://api.github.com/repos/${REPO}/releases/latest"
RAW="https://raw.githubusercontent.com/${REPO}"
VERSION_FILE="/opt/nexis-hypervisor/VERSION"
LOG="/var/log/nexis-update.log"

OR='\033[1;33m'; GRN='\033[1;32m'; RED='\033[1;31m'; RST='\033[0m'
_print() { printf '%b[nexis-update]%b %s\n' "$OR" "$RST" "$1"; }
_ok()    { printf '%b  ok%b  %s\n'          "$GRN" "$RST" "$1"; }
_err()   { printf '%b  err%b %s\n'          "$RED" "$RST" "$1" >&2; exit 1; }

[ "$EUID" -ne 0 ] && _err "must run as root"
exec 2>>"$LOG"

_print "Querying GitHub releases..."
REL=$(curl -fsSL --max-time 15 "$API") \
    || _err "Cannot reach GitHub API (check network)"

LATEST=$(printf '%s' "$REL" | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])") \
    || _err "Could not parse release JSON"

CURRENT=$(cat "$VERSION_FILE" 2>/dev/null || echo "v0.0.0")
_print "Installed: $CURRENT   Available: $LATEST"

if [ "$CURRENT" = "$LATEST" ]; then
    _ok "Already up to date ($LATEST)"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ── 1. Install .deb if present in release assets ──────────────────────────────
DEB_URL=$(printf '%s' "$REL" | python3 -c "
import sys, json
for a in json.load(sys.stdin).get('assets', []):
    if a['name'].endswith('.deb'):
        print(a['browser_download_url']); break
" 2>/dev/null || true)

if [ -n "$DEB_URL" ]; then
    _print "Downloading $(basename "$DEB_URL")..."
    curl -fsSL --max-time 300 --progress-bar "$DEB_URL" -o "$tmpdir/nexis.deb"
    _print "Installing package..."
    DEBIAN_FRONTEND=noninteractive dpkg -i "$tmpdir/nexis.deb" | tee -a "$LOG"
    _ok "Package installed"
else
    _print "No .deb asset in release — updating scripts only"
fi

# ── 2. Refresh management scripts from source ─────────────────────────────────
_print "Updating management scripts from $LATEST..."
declare -A SCRIPTS=(
    ["iso/nexis-shell.py"]="/usr/local/bin/nexis-shell"
    ["iso/nexis-update.sh"]="/usr/local/bin/nexis-update"
    ["iso/firstboot-tui.py"]="/usr/local/bin/nexis-firstboot"
)
for src in "${!SCRIPTS[@]}"; do
    dest="${SCRIPTS[$src]}"
    if curl -fsSL --max-time 30 "${RAW}/${LATEST}/${src}" -o "${dest}.tmp" 2>>"$LOG"; then
        mv "${dest}.tmp" "$dest"
        chmod +x "$dest"
        _ok "$(basename "$dest")"
    else
        rm -f "${dest}.tmp"
        _print "  (skipped $(basename "$dest") — not in release)"
    fi
done

# ── 3. Record new version ─────────────────────────────────────────────────────
mkdir -p "$(dirname "$VERSION_FILE")"
printf '%s\n' "$LATEST" > "$VERSION_FILE"

# ── 4. Reload and restart ─────────────────────────────────────────────────────
_print "Reloading systemd and restarting services..."
systemctl daemon-reload 2>>"$LOG"
# Stop old unit name if still present (migration from nexis-hypervisor → nexis-hypervisor-daemon)
systemctl stop nexis-hypervisor 2>/dev/null || true
systemctl restart nexis-hypervisor-daemon 2>>"$LOG" \
    && _ok "nexis-hypervisor-daemon restarted" \
    || _print "  (nexis-hypervisor-daemon not running — skipped)"

printf '\n'
_ok "Update complete: $CURRENT → $LATEST"
_print "Reload nexis-shell (press 0 then run 'nexis') to use new version."
