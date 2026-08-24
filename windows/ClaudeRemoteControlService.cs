using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
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
//   CLAUDE_RC_PROBE_HOST     host the startup network probe must reach
//   CLAUDE_RC_PROBE_TIMEOUT  seconds to wait for the network before giving up
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
        // Wait for the network on a worker thread. The SCM kills a service whose
        // OnStart blocks for more than ~30s, and on a cold boot the probe can
        // legitimately take minutes.
        new Thread(StartWhenNetworkReady) { IsBackground = true }.Start();
    }

    // At boot the service can start before DHCP, DNS, or a default route are
    // ready. Claude Code's Remote Control session creation is a one-shot at
    // startup: on failure the process does NOT exit, it keeps running and shows
    // "/rc failed", so the Exited restart hook never fires and the service looks
    // healthy while being permanently disconnected. Gate the launch on real
    // reachability instead.
    private void StartWhenNetworkReady()
    {
        try
        {
            if (WaitForNetwork())
            {
                StartChild();
                return;
            }
            if (_stopping) return;
            Log("Network never became reachable; exiting so the SCM restart action retries.");
        }
        catch (Exception ex)
        {
            Log("Startup failed: " + ex.Message);
        }
        Environment.Exit(1);
    }

    private bool WaitForNetwork()
    {
        var host = Environment.GetEnvironmentVariable("CLAUDE_RC_PROBE_HOST");
        if (string.IsNullOrEmpty(host)) host = "api.anthropic.com";

        int totalTimeout = 300;
        var raw = Environment.GetEnvironmentVariable("CLAUDE_RC_PROBE_TIMEOUT");
        if (!string.IsNullOrEmpty(raw)) int.TryParse(raw, out totalTimeout);

        const int port = 443;
        var deadline = DateTime.UtcNow.AddSeconds(totalTimeout);
        int attempt = 0;

        while (!_stopping)
        {
            attempt++;
            if (CanConnect(host, port))
            {
                Log("Network reachable (" + host + ":" + port + ") after " + attempt + " attempt(s)");
                return true;
            }
            if (DateTime.UtcNow >= deadline)
            {
                Log("Network probe to " + host + ":" + port + " failed for " + totalTimeout + "s");
                return false;
            }
            Thread.Sleep(2000);
        }
        return false;
    }

    // BeginConnect resolves the hostname itself, so a success proves DNS and
    // routing both work, not just that an address is configured.
    private static bool CanConnect(string host, int port)
    {
        try
        {
            using (var client = new TcpClient())
            {
                var ar = client.BeginConnect(host, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(TimeSpan.FromSeconds(5))) return false;
                client.EndConnect(ar);
                return client.Connected;
            }
        }
        catch { return false; }
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
