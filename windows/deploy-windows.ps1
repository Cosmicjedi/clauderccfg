<#
.SYNOPSIS
    Deploys a Windows service that starts a Claude Code Remote Control session
    at boot, then starts it immediately.

.DESCRIPTION
    Compiles ClaudeRemoteControlService.cs (a small ServiceBase wrapper) with
    the .NET Framework csc.exe present on every Windows machine, installs it as
    the 'ClaudeRemoteControl' service running as LocalSystem, and points the
    service at the deploying user's Claude Code profile via per-service
    environment variables (USERPROFILE etc.), so the session uses this user's
    credentials and settings. Also marks the working directory as trusted in
    ~\.claude.json and starts the service.

    Run from an elevated Windows PowerShell or PowerShell 7 prompt, as the user
    whose Claude Code login the service should use.

.PARAMETER SessionName
    Remote Control session name. Defaults to the computer name.

.PARAMETER WorkingDirectory
    Working directory for the session. Defaults to the system drive root.

.PARAMETER Uninstall
    Stop and remove the service and its install directory.

.EXAMPLE
    .\deploy-windows.ps1 -SessionName build-box -WorkingDirectory C:\src
#>
[CmdletBinding()]
param(
    [string]$SessionName = $env:COMPUTERNAME,
    [string]$WorkingDirectory = "$env:SystemDrive\",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$ServiceName = 'ClaudeRemoteControl'
$InstallDir  = Join-Path $env:ProgramFiles 'ClaudeRemoteControl'

$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run from an elevated (Administrator) prompt.'
}

function Remove-ExistingService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 2
    }
}

if ($Uninstall) {
    Remove-ExistingService
    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir -Confirm:$false
    }
    Write-Host "Removed service '$ServiceName'."
    return
}

$WorkingDirectory = (Resolve-Path $WorkingDirectory).Path

#region trust
# Marks $Dir as trusted in the Claude Code config at $ConfigPath, so the
# session does not block on the trust dialog. Uses JavaScriptSerializer on
# Windows PowerShell 5.1 (ConvertFrom-Json there chokes on large files) and
# ConvertFrom-Json -AsHashtable on PowerShell 7+.
function Set-ClaudeProjectTrust {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Dir
    )

    if (Test-Path $ConfigPath) {
        Copy-Item $ConfigPath "$ConfigPath.bak" -Force
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $data = @{}
        if (Test-Path $ConfigPath) {
            $data = Get-Content $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        }
        if (-not $data['projects']) { $data['projects'] = @{} }
        if (-not $data['projects'][$Dir]) { $data['projects'][$Dir] = @{} }
        $data['projects'][$Dir]['hasTrustDialogAccepted'] = $true
        $data['projects'][$Dir]['hasCompletedProjectOnboarding'] = $true
        $text = $data | ConvertTo-Json -Depth 100
    }
    else {
        # The edit runs entirely in C#: mutating the deserialized graph from
        # PowerShell wraps values in PSObject, which JavaScriptSerializer
        # cannot serialize back.
        if (-not ('ClaudeTrust' -as [type])) {
            Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;
public static class ClaudeTrust
{
    public static void Apply(string path, string dir)
    {
        var ser = new JavaScriptSerializer();
        ser.MaxJsonLength = int.MaxValue;
        ser.RecursionLimit = 1000;
        IDictionary<string, object> root = null;
        if (File.Exists(path))
            root = ser.DeserializeObject(File.ReadAllText(path)) as IDictionary<string, object>;
        if (root == null)
            root = new Dictionary<string, object>();
        object projObj;
        if (!root.TryGetValue("projects", out projObj) || !(projObj is IDictionary<string, object>))
        {
            projObj = new Dictionary<string, object>();
            root["projects"] = projObj;
        }
        var projects = (IDictionary<string, object>)projObj;
        object entryObj;
        if (!projects.TryGetValue(dir, out entryObj) || !(entryObj is IDictionary<string, object>))
        {
            entryObj = new Dictionary<string, object>();
            projects[dir] = entryObj;
        }
        var entry = (IDictionary<string, object>)entryObj;
        entry["hasTrustDialogAccepted"] = true;
        entry["hasCompletedProjectOnboarding"] = true;
        // UTF-8 without BOM — a BOM would break Claude Code's JSON parsing.
        File.WriteAllText(path, ser.Serialize(root));
    }
}
'@
        }
        [ClaudeTrust]::Apply($ConfigPath, $Dir)
        return
    }

    # Write UTF-8 without BOM — a BOM would break Claude Code's JSON parsing.
    [System.IO.File]::WriteAllText($ConfigPath, $text)
}
#endregion trust

# Locate the claude launcher for the current user.
$claudeCmd = $null
$cmdInfo = Get-Command claude -ErrorAction SilentlyContinue
if ($cmdInfo) { $claudeCmd = $cmdInfo.Source }
if (-not $claudeCmd) {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $claudeCmd = $c; break }
    }
}
if (-not $claudeCmd) {
    throw "Could not find 'claude'. Install Claude Code for this user first."
}

# A .cmd/.bat shim (npm install) must be launched through cmd.exe; a native
# claude.exe is launched directly.
if ($claudeCmd -match '\.(cmd|bat)$') {
    $childExe  = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $childArgs = '/d /s /c ""{0}" --remote-control "{1}""' -f $claudeCmd, $SessionName
}
else {
    $childExe  = $claudeCmd
    $childArgs = '--remote-control "{0}"' -f $SessionName
}

$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
Set-ClaudeProjectTrust -ConfigPath $claudeJson -Dir $WorkingDirectory
Write-Host "Trusted '$WorkingDirectory' in $claudeJson"

# Compile the service wrapper with the .NET Framework compiler.
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
    throw '.NET Framework 4.x compiler (csc.exe) not found.'
}

$srcPath = Join-Path $PSScriptRoot 'ClaudeRemoteControlService.cs'
if (-not (Test-Path $srcPath)) {
    throw "ClaudeRemoteControlService.cs not found next to this script."
}

Remove-ExistingService

New-Item -ItemType Directory -Force $InstallDir | Out-Null
$exePath = Join-Path $InstallDir 'ClaudeRemoteControlService.exe'
& $csc /nologo /optimize+ "/out:$exePath" /r:System.ServiceProcess.dll $srcPath
if ($LASTEXITCODE -ne 0) { throw 'Compilation of the service wrapper failed.' }

New-Service -Name $ServiceName `
    -BinaryPathName "`"$exePath`"" `
    -DisplayName 'Claude Code Remote Control' `
    -Description "Runs a Claude Code Remote Control session ($SessionName) at boot." `
    -StartupType Automatic | Out-Null

# Per-service environment: point the LocalSystem service at this user's
# profile so Claude Code finds ~\.claude and ~\.claude.json, hand the wrapper
# its launch configuration, and carry over PATH (for node, git, etc.).
$svcEnv = @(
    "USERPROFILE=$env:USERPROFILE",
    "HOMEDRIVE=$env:HOMEDRIVE",
    "HOMEPATH=$env:HOMEPATH",
    "APPDATA=$env:APPDATA",
    "LOCALAPPDATA=$env:LOCALAPPDATA",
    "TEMP=$env:TEMP",
    "TMP=$env:TMP",
    "PATH=$env:Path",
    "CLAUDE_RC_EXE=$childExe",
    "CLAUDE_RC_ARGS=$childArgs",
    "CLAUDE_RC_CWD=$WorkingDirectory"
)
$svcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
New-ItemProperty -Path $svcKey -Name 'Environment' -PropertyType MultiString -Value $svcEnv -Force | Out-Null

# Restart the whole service if the wrapper itself ever dies.
sc.exe failure $ServiceName reset= 86400 actions= restart/10000/restart/10000/restart/10000 | Out-Null

Start-Service -Name $ServiceName
$svc = Get-Service -Name $ServiceName

Write-Host ''
Write-Host "Service '$ServiceName' installed. Status: $($svc.Status)"
Write-Host "Session name:      $SessionName"
Write-Host "Working directory: $WorkingDirectory"
Write-Host "Wrapper log:       $InstallDir\service.log"
Write-Host 'Connect from claude.ai/code (Remote Control) — no reboot needed.'
