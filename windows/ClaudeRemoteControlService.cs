using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Threading;

// Windows service wrapper that launches "claude --remote-control" at boot and
// restarts it if it exits. The child is spawned without I/O redirection and
// with CreateNoWindow = false, so Windows allocates it a real (invisible in
// session 0) console — Claude Code's interactive UI requires a TTY.
//
// Configuration comes from per-service environment variables written by
// deploy-windows.ps1 to
// HKLM\SYSTEM\CurrentControlSet\Services\ClaudeRemoteControl\Environment:
//   CLAUDE_RC_EXE   executable to run (claude.exe, or cmd.exe for a .cmd shim)
//   CLAUDE_RC_ARGS  argument string
//   CLAUDE_RC_CWD   working directory for the session
public class ClaudeRemoteControlService : ServiceBase
{
    private Process _proc;
    private volatile bool _stopping;
    private string _logPath;

    public ClaudeRemoteControlService()
    {
        ServiceName = "ClaudeRemoteControl";
        CanStop = true;
    }

    private void Log(string msg)
    {
        try
        {
            File.AppendAllText(_logPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine);
        }
        catch { }
    }

    protected override void OnStart(string[] args)
    {
        _logPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "service.log");
        Log("Service starting");
        StartChild();
    }

    private void StartChild()
    {
        if (_stopping) return;

        var psi = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("CLAUDE_RC_EXE"),
            Arguments = Environment.GetEnvironmentVariable("CLAUDE_RC_ARGS"),
            WorkingDirectory = Environment.GetEnvironmentVariable("CLAUDE_RC_CWD"),
            UseShellExecute = false,
            CreateNoWindow = false
        };

        _proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        _proc.Exited += (s, e) =>
        {
            try { Log("claude exited with code " + _proc.ExitCode); } catch { }
            if (!_stopping)
            {
                Thread.Sleep(10000);
                try { StartChild(); }
                catch (Exception ex) { Log("Restart failed: " + ex.Message); }
            }
        };
        _proc.Start();
        Log("claude started, pid " + _proc.Id + ", cwd " + psi.WorkingDirectory);
    }

    protected override void OnStop()
    {
        _stopping = true;
        Log("Service stopping");
        try
        {
            if (_proc != null && !_proc.HasExited) _proc.Kill();
        }
        catch { }
    }

    public static void Main()
    {
        ServiceBase.Run(new ClaudeRemoteControlService());
    }
}
