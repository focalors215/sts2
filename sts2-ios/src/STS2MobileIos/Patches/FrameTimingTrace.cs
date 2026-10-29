using System;
using System.Diagnostics;
using System.IO;
using Godot;

namespace STS2MobileIos.Patches;

// Opt-in device diagnostics. No per-frame output unless a visible hitch occurs.
internal static class FrameTimingTrace
{
    private static bool _attached;
    public static void Attach(SceneTree tree)
    {
        if (_attached || tree == null || !File.Exists(Path.Combine(OS.GetUserDataDir(), "perf_trace_on"))) return;
        _attached = true;
        var tracePath = Path.Combine(OS.GetUserDataDir(), "frame-timing.log");
        void Record(string message)
        {
            PatchHelper.Log(message);
            // Console attachment is optional on-device; retain the small hitch
            // trace even when the user launches the app from its Home icon.
            try { File.AppendAllText(tracePath, $"{DateTime.UtcNow:O} {message}\n"); }
            catch { /* Diagnostics must never interrupt gameplay. */ }
        }
        long last = Stopwatch.GetTimestamp();
        double canvas = Performance.GetMonitor(Performance.Monitor.PipelineCompilationsCanvas);
        double draw = Performance.GetMonitor(Performance.Monitor.PipelineCompilationsDraw);
        tree.ProcessFrame += () =>
        {
            long now = Stopwatch.GetTimestamp();
            double gap = (now - last) * 1000.0 / Stopwatch.Frequency;
            last = now;
            double nextCanvas = Performance.GetMonitor(Performance.Monitor.PipelineCompilationsCanvas);
            double nextDraw = Performance.GetMonitor(Performance.Monitor.PipelineCompilationsDraw);
            if (gap >= 80)
                Record($"[FrameTrace] gap={gap:F0}ms process={Performance.GetMonitor(Performance.Monitor.TimeProcess) * 1000:F0}ms physics={Performance.GetMonitor(Performance.Monitor.TimePhysicsProcess) * 1000:F0}ms canvas+={nextCanvas - canvas} draw+={nextDraw - draw}");
            canvas = nextCanvas;
            draw = nextDraw;
        };
        Record("[FrameTrace] enabled (hitches >=80ms)");
    }
}
