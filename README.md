# Claude Code Remote Control — boot services

Services for Linux, macOS, and Windows that launch a Claude Code session with
[Remote Control](https://docs.anthropic.com/en/docs/claude-code) enabled at
system boot, plus a deployment script per OS. After deployment the session is
immediately reachable from claude.ai/code — no reboot required.

## Layout

| Path | Purpose |
|---|---|
| `linux/deploy-linux.sh` | Installs a systemd system service (`claude-remote-control`) |
| `macos/deploy-macos.sh` | Installs a LaunchDaemon (`com.claude.remote-control`) |
| `windows/deploy-windows.ps1` | Compiles + installs a Windows service (`ClaudeRemoteControl`) |
| `windows/ClaudeRemoteControlService.cs` | ServiceBase wrapper the Windows script compiles at deploy time |

## Switches

Every script takes the same options:

- **Session name** — `-n` / `--session-name` (Linux/macOS), `-SessionName`
  (Windows). Defaults to the machine's hostname.
- **Working directory** — `-w` / `--workdir` (Linux/macOS),
  `-WorkingDirectory` (Windows). Defaults to the system root (`/` or `C:\`).
- **Probe host** — `--probe-host` (Linux/macOS), `-ProbeHost` (Windows). The
  host the boot-time network gate must reach. Defaults to `api.anthropic.com`.
- **Probe timeout** — `--probe-timeout` (Linux/macOS),
  `-ProbeTimeoutSeconds` (Windows). Seconds to wait for the network before
  failing the start so the restart policy retries. Defaults to `300`.

Each script also accepts `--uninstall` / `-Uninstall` to remove the service.

## What the scripts do

1. Locate the `claude` binary for the deploying user.
2. Edit that user's `~/.claude.json` (a `.bak` backup is written first),
   setting `projects.<workdir>.hasTrustDialogAccepted = true` (and
   `hasCompletedProjectOnboarding`) so the session never blocks on the trust
   dialog.
3. Install a network preflight gate at `/usr/local/libexec/claude-rc-preflight`
   (Unix) or compile it into the service wrapper (Windows), and make the
   service launch the session only once that gate reports the API reachable.
4. Install a boot-time service that runs
   `claude --remote-control <session-name>` in the chosen working directory,
   restarting it automatically if it exits.
5. Start the service immediately.

## Usage

```bash
# Linux
sudo ./linux/deploy-linux.sh -n my-server -w /srv/app

# macOS
sudo ./macos/deploy-macos.sh -n my-mac -w /Users/me/project
```

```powershell
# Windows (elevated prompt, run as the user whose Claude login should be used)
.\windows\deploy-windows.ps1 -SessionName my-pc -WorkingDirectory C:\src
```

## Prerequisites

- Claude Code installed **and authenticated** for the user running the deploy
  script (the Unix scripts use `sudo`; the service runs as the invoking user,
  i.e. `$SUDO_USER`).
- Linux: `python3` (for the JSON edit) and `script` from util-linux (both are
  present on virtually every distro).
- Windows: any .NET Framework 4.x machine (the built-in `csc.exe` compiles the
  wrapper; no SDK install needed).

## How the TTY problem is solved

Claude Code's interactive UI requires a terminal, which services don't have:

- **Linux/macOS** — the launch is wrapped in `script -q … /dev/null`, which
  allocates a pseudo-terminal for the session.
- **Windows** — the service wrapper spawns claude without I/O redirection and
  with `CreateNoWindow = false`, so Windows allocates a real console (invisible
  in session 0), which satisfies the TTY check. The service runs as
  LocalSystem, with per-service environment variables (`USERPROFILE`, `PATH`,
  …) pointing it at the deploying user's Claude profile.

## Why there is a network preflight gate

Without it, these services reliably come up **disconnected after a reboot** and
need a manual restart. Two things combine:

**1. "Network is online" is a lie.** On Ubuntu with netplan,
`systemd-networkd-wait-online` carries a generated drop-in at
`/run/systemd/system/systemd-networkd-wait-online.service.d/10-netplan.conf`:

```ini
[Unit]
ConditionPathIsSymbolicLink=/run/systemd/generator/network-online.target.wants/systemd-networkd-wait-online.service
```

When netplan does not create that symlink, the waiter is silently skipped and
`network-online.target` is reached in milliseconds with nothing behind it, so
`After=network-online.target` buys nothing. Observed on a real host: the target
was reached at `10:25:22.687`, the service started at `10:25:22.692`, and the
interface did not get its DHCP lease until `10:25:25.78` — the session tried to
connect **3.1 seconds before the machine had an IP address**. macOS `RunAtLoad`
and Windows automatic-start have the same hazard.

**2. The failure does not self-heal.** Remote Control session creation is a
one-shot at startup. When it fails, `claude` does **not** exit — it stays
running and displays `/rc failed`. Because nothing exited, `Restart=always`
(systemd), `KeepAlive` (launchd), and the wrapper's `Exited` hook (Windows)
never fire. `systemctl status` cheerfully reports `active (running)` over a
session that is permanently disconnected.

So the gate blocks the launch until an actual HTTPS connection to the probe host
succeeds — proving DNS, routing, and TLS all work, not merely that an address is
configured. If the gate times out it exits non-zero, which *does* trip the
restart policy, so a slow or flapping network converges instead of wedging.

Supporting details per platform:

- **Linux** — `ExecStartPre=` runs the gate. `TimeoutStartSec` is raised above
  the probe budget (systemd would otherwise kill the start mid-wait) and
  `StartLimitIntervalSec=0` keeps a long outage from burning the default
  5-starts-per-10s budget and wedging the unit in `failed`.
- **macOS** — launchd has no `ExecStartPre`, so the gate and the session share
  one `bash -c` invocation and the session is `exec`d, keeping the supervised
  pid the session itself.
- **Windows** — the probe runs on a worker thread, because the SCM kills a
  service whose `OnStart` blocks longer than ~30s. The service is also set to
  delayed auto-start and to depend on `Tcpip`/`Dnscache`.

## Caveats

- **Security**: this exposes a Claude Code session rooted at (by default) the
  entire filesystem to anyone with access to your claude.ai account, starting
  at every boot. Protect the account with strong auth, and consider a narrower
  working directory.
- **macOS Keychain**: if the OAuth token lives only in the login Keychain, a
  boot-time daemon can't read it before login. The deploy script warns when
  `~/.claude/.credentials.json` is absent; `claude setup-token` or an API key
  avoids the issue.
- **Session name characters**: stick to letters, digits, `-`, `_`, and `.` —
  the name is embedded in service definitions.
- The Unix services run `claude` found on the deploying user's PATH; if you
  update or move the binary, re-run the deploy script.

## Logs & management

```bash
# Linux
systemctl status claude-remote-control
journalctl -u claude-remote-control -f

# macOS
launchctl print system/com.claude.remote-control
tail -f /var/log/claude-remote-control.log
```

```powershell
# Windows
Get-Service ClaudeRemoteControl
Get-Content "$env:ProgramFiles\ClaudeRemoteControl\service.log" -Tail 20
```
