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

Every script takes the same two options:

- **Session name** — `-n` / `--session-name` (Linux/macOS), `-SessionName`
  (Windows). Defaults to the machine's hostname.
- **Working directory** — `-w` / `--workdir` (Linux/macOS),
  `-WorkingDirectory` (Windows). Defaults to the system root (`/` or `C:\`).

Each script also accepts `--uninstall` / `-Uninstall` to remove the service.

## What the scripts do

1. Locate the `claude` binary for the deploying user.
2. Edit that user's `~/.claude.json` (a `.bak` backup is written first),
   setting `projects.<workdir>.hasTrustDialogAccepted = true` (and
   `hasCompletedProjectOnboarding`) so the session never blocks on the trust
   dialog.
3. Install a boot-time service that runs
   `claude --remote-control <session-name>` in the chosen working directory,
   restarting it automatically if it exits.
4. Start the service immediately.

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
