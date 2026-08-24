#!/usr/bin/env bash
# Deploys a macOS LaunchDaemon that starts a Claude Code Remote Control
# session at boot, then starts it immediately.
#
# Usage: sudo ./deploy-macos.sh [-n NAME] [-w DIR] [--uninstall]
set -euo pipefail

LABEL="com.claude.remote-control"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
LOG_PATH="/var/log/claude-remote-control.log"
PREFLIGHT_PATH="/usr/local/libexec/claude-rc-preflight"

usage() {
  cat <<'EOF'
Usage: sudo ./deploy-macos.sh [options]

  -n, --session-name NAME  Remote Control session name (default: hostname)
  -w, --workdir DIR        Working directory for the session (default: /)
      --probe-host HOST    Host the startup network probe must reach
                           (default: api.anthropic.com)
      --probe-timeout SEC  How long to wait for the network before failing the
                           start and letting launchd retry (default: 300)
      --uninstall          Stop and remove the LaunchDaemon
  -h, --help               Show this help
EOF
}

SESSION_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname)"
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
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST_PATH" "$PREFLIGHT_PATH"
  echo "Removed ${LABEL}."
  exit 0
fi

# The daemon runs as the user who invoked sudo, so it can use that user's
# Claude Code configuration.
SERVICE_USER="${SUDO_USER:-root}"
HOME_DIR="$(dscl . -read "/Users/${SERVICE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  echo "Could not resolve home directory for user '$SERVICE_USER'." >&2
  exit 1
fi

if [[ ! -d "$WORKDIR" ]]; then
  echo "Working directory '$WORKDIR' does not exist." >&2
  exit 1
fi
WORKDIR="$(cd "$WORKDIR" && pwd)"

# Locate the claude binary using the service user's PATH.
CLAUDE_BIN="$(sudo -u "$SERVICE_USER" bash -lc 'command -v claude' 2>/dev/null || true)"
if [[ -z "$CLAUDE_BIN" ]]; then
  for c in "$HOME_DIR/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [[ -x "$c" ]]; then CLAUDE_BIN="$c"; break; fi
  done
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "Could not find the 'claude' binary for user '$SERVICE_USER'. Install Claude Code first." >&2
  exit 1
fi

# Mark the working directory as trusted in the service user's ~/.claude.json
# so the session does not block on the trust dialog. Uses osascript (JXA)
# because it is always present on macOS.
CLAUDE_JSON="$HOME_DIR/.claude.json"
if [[ -f "$CLAUDE_JSON" ]]; then
  cp "$CLAUDE_JSON" "$CLAUDE_JSON.bak"
fi
TRUST_JS="$(mktemp -t claude-trust).js"
cat > "$TRUST_JS" <<'JSEOF'
ObjC.import('Foundation');
function run(argv) {
  var path = argv[0], workdir = argv[1];
  var data = {};
  var fm = $.NSFileManager.defaultManager;
  if (fm.fileExistsAtPath(path)) {
    var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
    data = JSON.parse(ObjC.unwrap(s));
  }
  if (!data.projects) data.projects = {};
  if (!data.projects[workdir]) data.projects[workdir] = {};
  data.projects[workdir].hasTrustDialogAccepted = true;
  data.projects[workdir].hasCompletedProjectOnboarding = true;
  var out = $(JSON.stringify(data, null, 2));
  out.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
JSEOF
osascript -l JavaScript "$TRUST_JS" "$CLAUDE_JSON" "$WORKDIR"
rm -f "$TRUST_JS"
chown "$SERVICE_USER" "$CLAUDE_JSON"
echo "Trusted '$WORKDIR' in $CLAUDE_JSON"

# Warn if credentials appear to live only in the login Keychain — a boot-time
# daemon cannot read the Keychain before login.
if [[ ! -f "$HOME_DIR/.claude/.credentials.json" ]]; then
  echo "WARNING: $HOME_DIR/.claude/.credentials.json not found." >&2
  echo "If Claude Code stores its OAuth token in the macOS Keychain, the daemon" >&2
  echo "cannot read it at boot. Consider 'claude setup-token' or an API key." >&2
fi

# Install the network preflight gate.
#
# Why this exists: RunAtLoad fires before the machine reliably has DHCP, DNS, or
# a default route, and Claude Code's Remote Control session creation is a
# one-shot at startup: on failure the process does NOT exit, it keeps running
# and shows "/rc failed". KeepAlive therefore never fires (nothing exited) and
# the daemon looks healthy while being permanently disconnected, recoverable
# only by a manual restart. Gating launch on real reachability prevents that.
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

# '/usr/bin/script' allocates a pty so Claude Code's interactive UI can run
# headless; its own stdout is copied to the log file.
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <!-- launchd has no ExecStartPre, so the preflight gate and the session share
       one bash invocation: wait for real connectivity, then exec the session so
       the pid launchd supervises is the session itself. A failed probe exits
       non-zero, and KeepAlive retries after ThrottleInterval. -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>${PREFLIGHT_PATH} ${PROBE_HOST} 443 ${PROBE_TIMEOUT} &amp;&amp; exec /usr/bin/script -q /dev/null '${CLAUDE_BIN}' --remote-control '${SESSION_NAME}'</string>
  </array>
  <key>UserName</key><string>${SERVICE_USER}</string>
  <key>WorkingDirectory</key><string>${WORKDIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME_DIR}</string>
    <key>TERM</key><string>xterm-256color</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG_PATH}</string>
  <key>StandardErrorPath</key><string>${LOG_PATH}</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST_PATH"
chown root:wheel "$PLIST_PATH"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST_PATH"
launchctl kickstart -k "system/${LABEL}" 2>/dev/null || true

echo
launchctl print "system/${LABEL}" 2>/dev/null | head -n 15 || true
echo
echo "LaunchDaemon '${LABEL}' is installed and running."
echo "Session name:      ${SESSION_NAME}"
echo "Working directory: ${WORKDIR}"
echo "Log:               ${LOG_PATH}"
echo "Connect from claude.ai/code (Remote Control) — no reboot needed."
