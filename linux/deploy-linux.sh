#!/usr/bin/env bash
# Deploys a systemd system service that starts a Claude Code Remote Control
# session at boot, then starts it immediately.
#
# Usage: sudo ./deploy-linux.sh [-n NAME] [-w DIR] [--uninstall]
set -euo pipefail

SERVICE_NAME="claude-remote-control"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

usage() {
  cat <<'EOF'
Usage: sudo ./deploy-linux.sh [options]

  -n, --session-name NAME  Remote Control session name (default: hostname)
  -w, --workdir DIR        Working directory for the session (default: /)
      --uninstall          Stop, disable, and remove the service
  -h, --help               Show this help
EOF
}

SESSION_NAME="$(hostname)"
WORKDIR="/"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--session-name) SESSION_NAME="$2"; shift 2 ;;
    -w|--workdir)      WORKDIR="$2"; shift 2 ;;
    --uninstall)       UNINSTALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must run as root (use sudo)." >&2
  exit 1
fi

if [[ $UNINSTALL -eq 1 ]]; then
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  echo "Removed ${SERVICE_NAME}."
  exit 0
fi

# The service runs as the user who invoked sudo, so it can use that user's
# Claude Code credentials (~/.claude).
SERVICE_USER="${SUDO_USER:-root}"
HOME_DIR="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  echo "Could not resolve home directory for user '$SERVICE_USER'." >&2
  exit 1
fi

WORKDIR="$(readlink -f "$WORKDIR")"
if [[ ! -d "$WORKDIR" ]]; then
  echo "Working directory '$WORKDIR' does not exist." >&2
  exit 1
fi

# Locate the claude binary using the service user's PATH.
CLAUDE_BIN="$(sudo -u "$SERVICE_USER" bash -lc 'command -v claude' 2>/dev/null || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  for c in "$HOME_DIR/.local/bin/claude" /usr/local/bin/claude /usr/bin/claude; do
    if [[ -x "$c" ]]; then CLAUDE_BIN="$c"; break; fi
  done
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "Could not find the 'claude' binary for user '$SERVICE_USER'. Install Claude Code first." >&2
  exit 1
fi

SCRIPT_BIN="$(command -v script)"
if [[ -z "$SCRIPT_BIN" ]]; then
  echo "'script' (util-linux) is required to give the session a pseudo-terminal." >&2
  exit 1
fi

# Mark the working directory as trusted in the service user's ~/.claude.json
# so the session does not block on the trust dialog.
CLAUDE_JSON="$HOME_DIR/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  cp "$CLAUDE_JSON" "$CLAUDE_JSON.bak"
fi
python3 - "$CLAUDE_JSON" "$WORKDIR" <<'PYEOF'
import json, os, sys

path, workdir = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
project = data.setdefault("projects", {}).setdefault(workdir, {})
project["hasTrustDialogAccepted"] = True
project["hasCompletedProjectOnboarding"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
chown "$SERVICE_USER": "$CLAUDE_JSON"
echo "Trusted '$WORKDIR' in $CLAUDE_JSON"

# 'script' allocates a pty so Claude Code's interactive UI can run headless.
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Claude Code Remote Control (${SESSION_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${WORKDIR}
Environment=HOME=${HOME_DIR}
Environment=TERM=xterm-256color
ExecStart=${SCRIPT_BIN} -qefc "'${CLAUDE_BIN}' --remote-control '${SESSION_NAME}'" /dev/null
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

echo
systemctl --no-pager --lines=0 status "$SERVICE_NAME" || true
echo
echo "Service '${SERVICE_NAME}' is installed and running."
echo "Session name:      ${SESSION_NAME}"
echo "Working directory: ${WORKDIR}"
echo "Connect from claude.ai/code (Remote Control) — no reboot needed."
