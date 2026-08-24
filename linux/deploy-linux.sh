#!/usr/bin/env bash
# Deploys a systemd system service that starts a Claude Code Remote Control
# session at boot, then starts it immediately.
#
# Usage: sudo ./deploy-linux.sh [-n NAME] [-w DIR] [--uninstall]
set -euo pipefail

SERVICE_NAME="claude-remote-control"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
PREFLIGHT_PATH="/usr/local/libexec/claude-rc-preflight"

usage() {
  cat <<'EOF'
Usage: sudo ./deploy-linux.sh [options]

  -n, --session-name NAME  Remote Control session name (default: hostname)
  -w, --workdir DIR        Working directory for the session (default: /)
      --probe-host HOST    Host the startup network probe must reach
                           (default: api.anthropic.com)
      --probe-timeout SEC  How long to wait for the network before failing the
                           start and letting systemd retry (default: 300)
      --uninstall          Stop, disable, and remove the service
  -h, --help               Show this help
EOF
}

SESSION_NAME="$(hostname)"
WORKDIR="/"
PROBE_HOST="api.anthropic.com"
PROBE_TIMEOUT=300
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--session-name) SESSION_NAME="$2"; shift 2 ;;
    -w|--workdir)      WORKDIR="$2"; shift 2 ;;
    --probe-host)      PROBE_HOST="$2"; shift 2 ;;
    --probe-timeout)   PROBE_TIMEOUT="$2"; shift 2 ;;
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
  rm -f "$UNIT_PATH" "$PREFLIGHT_PATH"
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

# Install the network preflight gate.
#
# Why this exists: "network-online.target" is not a reliable signal. On Ubuntu
# with netplan, systemd-networkd-wait-online carries a drop-in
# (/run/systemd/system/systemd-networkd-wait-online.service.d/10-netplan.conf)
# adding ConditionPathIsSymbolicLink=/run/systemd/generator/network-online.target.wants/systemd-networkd-wait-online.service.
# When netplan does not create that symlink the waiter is silently skipped,
# network-online.target is reached in milliseconds with nothing behind it, and
# services ordered After= it start seconds before DHCP has assigned an address.
#
# That is fatal here specifically because Claude Code's Remote Control session
# creation is a one-shot at startup: on failure the process does NOT exit, it
# keeps running and shows "/rc failed". Restart= never fires (nothing exited),
# so systemd reports the unit active while the session is permanently
# disconnected, and only a manual restart recovers it.
mkdir -p "$(dirname "$PREFLIGHT_PATH")"
cat > "$PREFLIGHT_PATH" <<'PFEOF'
#!/usr/bin/env bash
# Blocks until the Claude API is genuinely reachable, then exits 0.
# Exits 1 on timeout so the caller's restart policy tries again.
#
# Usage: claude-rc-preflight [HOST] [PORT] [TOTAL_TIMEOUT_SECONDS]
set -u

HOST="${1:-api.anthropic.com}"
PORT="${2:-443}"
TOTAL_TIMEOUT="${3:-300}"
CONNECT_TIMEOUT=5
SLEEP_BETWEEN=2

probe() {
  if command -v curl >/dev/null 2>&1; then
    # Any HTTP response proves DNS + routing + TLS all work end to end; the
    # status code itself is irrelevant.
    curl -sS --max-time "$CONNECT_TIMEOUT" -o /dev/null "https://${HOST}:${PORT}/" >/dev/null 2>&1
    return $?
  fi
  # Fallback: a raw TCP connect via bash's /dev/tcp. Backgrounded and killed by
  # hand rather than wrapped in 'timeout', which macOS does not ship.
  ( exec 3<>"/dev/tcp/${HOST}/${PORT}" ) >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$CONNECT_TIMEOUT" ]; then
      kill -9 "$pid" >/dev/null 2>&1
      wait "$pid" 2>/dev/null
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

start="$(date +%s)"
attempt=0
while :; do
  attempt=$((attempt + 1))
  if probe; then
    echo "claude-rc-preflight: ${HOST}:${PORT} reachable after ${attempt} attempt(s), $(( $(date +%s) - start ))s"
    exit 0
  fi
  if [ "$(( $(date +%s) - start ))" -ge "$TOTAL_TIMEOUT" ]; then
    echo "claude-rc-preflight: ${HOST}:${PORT} unreachable after ${TOTAL_TIMEOUT}s; failing so the service restarts" >&2
    exit 1
  fi
  sleep "$SLEEP_BETWEEN"
done
PFEOF
chmod 755 "$PREFLIGHT_PATH"
echo "Installed network preflight gate at $PREFLIGHT_PATH"

# 'script' allocates a pty so Claude Code's interactive UI can run headless.
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Claude Code Remote Control (${SESSION_NAME})
After=network-online.target
Wants=network-online.target
# network-online.target can be reached vacuously, so ExecStartPre below does the
# real waiting. Disable the start rate limiter: a long outage would otherwise
# burn through the default 5-starts-per-10s budget and wedge the unit in failed.
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${WORKDIR}
Environment=HOME=${HOME_DIR}
Environment=TERM=xterm-256color
# Refuse to launch until the API is actually reachable. If this exits non-zero
# Restart=always retries, so a slow or flapping network self-heals.
ExecStartPre=${PREFLIGHT_PATH} ${PROBE_HOST} 443 ${PROBE_TIMEOUT}
ExecStart=${SCRIPT_BIN} -qefc "'${CLAUDE_BIN}' --remote-control '${SESSION_NAME}'" /dev/null
Restart=always
RestartSec=10
# Must exceed the preflight budget or systemd kills the start mid-wait.
TimeoutStartSec=$((PROBE_TIMEOUT + 60))

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
