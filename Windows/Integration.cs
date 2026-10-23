using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace PetsPetWindows
{
    static class SidebarLauncher
    {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct ProcessEntry
        {
            public uint Size, Usage, Id; public UIntPtr Heap; public uint Module, Threads, Parent;
            public int Priority; public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Name;
        }
        [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint process);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        static HashSet<int> RootIds(IEnumerable<int> processes)
        {
            HashSet<int> ids = new HashSet<int>(processes), children = new HashSet<int>();
            IntPtr snapshot = CreateToolhelp32Snapshot(2,0);
            if (snapshot == new IntPtr(-1)) return ids;
            try {
                ProcessEntry entry = new ProcessEntry { Size = (uint)Marshal.SizeOf(typeof(ProcessEntry)) };
                if (Process32FirstW(snapshot, ref entry)) do {
                    if (ids.Contains((int)entry.Parent)) children.Add((int)entry.Id);
                } while (Process32NextW(snapshot, ref entry));
            } finally { CloseHandle(snapshot); }
            ids.ExceptWith(children); return ids;
        }
        internal static bool IsCodexExecutable(string path)
        {
            return !String.IsNullOrEmpty(path) && Path.IsPathRooted(path) && String.Equals(Path.GetFileName(path), "ChatGPT.exe", StringComparison.OrdinalIgnoreCase) &&
                (path.IndexOf(@"\WindowsApps\OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0 || path.IndexOf(@"\OpenAI\Codex\", StringComparison.OrdinalIgnoreCase) >= 0);
        }
        static List<Process> Running()
        {
            List<Process> found = new List<Process>();
            foreach (Process process in Process.GetProcessesByName("ChatGPT")) {
                try { if (IsCodexExecutable(process.MainModule.FileName)) { found.Add(process); continue; } } catch { }
                process.Dispose();
            }
            HashSet<int> roots = RootIds(found.Select(p => p.Id));
            List<Process> main = found.Where(p => roots.Contains(p.Id)).ToList();
            foreach (Process child in found.Except(main)) child.Dispose();
            return main;
        }
        public static string FindExecutable(string remembered)
        {
            List<Process> running = Running();
            try {
                foreach (Process process in running) { try { return process.MainModule.FileName; } catch { } }
                return IsCodexExecutable(remembered) && File.Exists(remembered) ? remembered : null;
            }
            finally { foreach (Process process in running) process.Dispose(); }
        }
        public static object Diagnose(string remembered)
        {
            List<Process> running = Running();
            try { return new { codexMainProcesses = running.Count, validLaunchPath = FindExecutable(remembered) != null, debugConnectionReady = SidebarClient.Ready() }; }
            finally { foreach (Process process in running) process.Dispose(); }
        }
        internal static bool IsRunning()
        {
            List<Process> running = Running();
            try { return running.Count > 0; } finally { foreach (Process process in running) process.Dispose(); }
        }
        internal static ProcessStartInfo StartInfo(string executable)
        {
            if (!IsCodexExecutable(executable)) throw new ArgumentException("不是已确认的 Codex 程序路径。");
            return new ProcessStartInfo(executable, "--remote-debugging-address=127.0.0.1 --remote-debugging-port=39222") {
                UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)
            };
        }
        // The user exits Codex manually. This code never closes an app window.
        internal static string OpenSteps(Func<bool> running, Action launch, Func<bool> ready,
            Action<string> progress, CancellationToken cancel, int readyTimeout)
        {
            cancel.ThrowIfCancellationRequested();
            bool available = ready();
            cancel.ThrowIfCancellationRequested();
            if (available) return null;
            if (running()) return "请先手动完全退出 Codex，包括后台进程，再点击“连接侧栏”。本工具不会自动关闭窗口；不要从普通快捷方式重开 Codex。";
            cancel.ThrowIfCancellationRequested();
            progress("正在携带侧栏连接参数打开 Codex…");
            launch(); Stopwatch wait = Stopwatch.StartNew();
            progress("Codex 已启动，正在确认本机侧栏连接…");
            while (true) {
                cancel.ThrowIfCancellationRequested();
                available = ready();
                cancel.ThrowIfCancellationRequested();
                if (available) return null;
                if (wait.ElapsedMilliseconds >= readyTimeout) return "Codex 已重新打开，但侧栏连接没有开启。请勿同时从普通快捷方式重开 Codex；可完全退出后再次从 PetsPet 启用。若仍失败，此版 Codex 的启动参数兼容性需继续检查。";
                cancel.WaitHandle.WaitOne(250);
            }
        }
        public static string Open(string executable, Action<string> progress, CancellationToken cancel)
        {
            try {
                return OpenSteps(IsRunning, delegate {
                    using (Process opened = Process.Start(StartInfo(executable))) { if (opened == null) throw new IOException("Codex 启动失败。"); }
                }, SidebarClient.Ready, progress, cancel, 30000);
            }
            catch (System.ComponentModel.Win32Exception error) { return "Windows 未能打开 Codex（错误码 " + error.NativeErrorCode + "）。请先正常打开 Codex 一次更新安装路径，再重试连接。"; }
            catch (FileNotFoundException) { return "记住的 Codex 安装文件已不存在。请先正常打开新版 Codex 一次，再从 PetsPet 启用连接。"; }
        }
    }

    static class OriginalAssets
    {
        public static Icon ApplicationIcon()
        { using (Stream stream = typeof(OriginalAssets).Assembly.GetManifestResourceStream("PetsPet.AppIcon.ico")) return new Icon(stream, 32, 32); }
        public static Icon TrayIcon()
        {
            bool light = false;
            try { light = Convert.ToInt32(Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0)) != 0; } catch { }
            using (Stream stream = typeof(OriginalAssets).Assembly.GetManifestResourceStream("PetsPet.MenuBarIcon.png"))
            using (Bitmap source = new Bitmap(stream))
            using (Bitmap bitmap = new Bitmap(32, 32))
            {
                using (Graphics g = Graphics.FromImage(bitmap)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic; g.DrawImage(source, 0, 0, 32, 32); }
                for (int y = 0; y < bitmap.Height; y++) for (int x = 0; x < bitmap.Width; x++)
                    bitmap.SetPixel(x, y, Color.FromArgb(bitmap.GetPixel(x,y).A, light ? Color.Black : Color.White));
                IntPtr handle = bitmap.GetHicon();
                try { return (Icon)Icon.FromHandle(handle).Clone(); } finally { Native.DestroyIcon(handle); }
            }
        }
    }

    // A click must begin and end on the same exposed pet, with no intervening drag.
    sealed class PetGesture
    {
        Point start; long started; IntPtr window; bool down, moved;
        public void Down(Point point, IntPtr target, bool exposed, long milliseconds)
        { start = point; window = target; started = milliseconds; down = exposed && target != IntPtr.Zero; moved = false; }
        public void Move(Point point) { if (Math.Abs(point.X-start.X) > 4 || Math.Abs(point.Y-start.Y) > 4) moved = true; }
        public bool Up(Point point, IntPtr target, bool exposed, long milliseconds)
        { Move(point); bool click = down && !moved && exposed && window == target && milliseconds-started >= 0 && milliseconds-started < 700; down = false; return click; }
        public void Reset() { down = false; }
    }

    sealed class PetMouseMonitor : IDisposable
    {
        delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
        [StructLayout(LayoutKind.Sequential)] struct MouseData { public Native.Point Point; public uint Mouse, Flags, Time; public UIntPtr Extra; }
        [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int hook, HookProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Native.Point point);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
        readonly PetTracker tracker; readonly Action clicked; readonly PetGesture gesture = new PetGesture(); readonly HookProc callback;
        IntPtr hook; public bool Available { get { return hook != IntPtr.Zero; } }
        public PetMouseMonitor(PetTracker value, Action action) { tracker = value; clicked = action; callback = Handle; }
        public void Enable(bool enabled)
        {
            if (enabled && hook == IntPtr.Zero) hook = SetWindowsHookEx(14, callback, GetModuleHandle(null), 0);
            if (!enabled) Dispose();
        }
        IntPtr Handle(int code, IntPtr message, IntPtr data)
        {
            try
            {
                if (code >= 0 && tracker.Enabled)
                {
                    MouseData mouse = (MouseData)Marshal.PtrToStructure(data, typeof(MouseData));
                    Point point = new Point(mouse.Point.X, mouse.Point.Y);
                    int kind = message.ToInt32();
                    // Hook stays short: no accessibility, disk or network queries here.
                    if (kind == 0x200) { gesture.Move(point); tracker.WakeMotion(); }
                    if (kind == 0x201 || kind == 0x202)
                    {
                        PetAnchor anchor = tracker.Current;
                        bool exposed = anchor.Found && anchor.Pet.Contains(point) && GetAncestor(WindowFromPoint(mouse.Point), 2) == anchor.Window;
                        long time = Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;
                        if (kind == 0x201) gesture.Down(point, anchor.Window, exposed, time);
                        else { if (gesture.Up(point, anchor.Window, exposed, time)) clicked(); tracker.WakeMotion(); }
                    }
                }
            }
            catch { gesture.Reset(); }
            return CallNextHookEx(hook, code, message, data); // Always deliver the original mouse event.
        }
        public void Dispose() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } gesture.Reset(); }
    }

    // The same local DevTools protocol used upstream. No remote endpoints or redirects.
    sealed class SidebarClient : IDisposable
    {
        readonly object sync = new object(); readonly ManualResetEvent stop = new ManualResetEvent(false);
        string payload; bool enabled; string status = "侧栏尚未连接";
        public string Status { get { lock(sync) return status; } }
        void StatusText(string text) { lock(sync) status = text; }
        public SidebarClient() { new Thread(Run) { IsBackground = true, Name = "PetsPet sidebar" }.Start(); }
        public void Configure(bool active, string data) { lock(sync) { enabled = active; payload = data; } }
        public static bool AllowedSocket(string address)
        {
            Uri uri;
            return Uri.TryCreate(address, UriKind.Absolute, out uri) && uri.Scheme == "ws" && uri.Host == "127.0.0.1" && uri.Port == 39222 &&
                String.IsNullOrEmpty(uri.UserInfo) && String.IsNullOrEmpty(uri.Fragment) && uri.AbsolutePath.StartsWith("/devtools/page/", StringComparison.Ordinal);
        }
        static string Script()
        { using (Stream stream = typeof(SidebarClient).Assembly.GetManifestResourceStream("PetsPet.Sidebar.js")) using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) return reader.ReadToEnd(); }
        static List<string> Discover()
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:39222/json/list");
            request.Proxy = null; request.AllowAutoRedirect = false; request.Timeout = request.ReadWriteTimeout = 1500;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
            {
                if (response.StatusCode != HttpStatusCode.OK) throw new IOException();
                char[] buffer = new char[1000001]; int count = 0, read;
                while (count < buffer.Length && (read = reader.Read(buffer, count, buffer.Length-count)) > 0) count += read;
                if (count == buffer.Length) throw new IOException();
                object[] targets = new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(new string(buffer,0,count)) as object[];
                if (targets == null) throw new IOException();
                return targets.Select(Json.Map).Where(t => Json.Text(t,"type") == "page" && MainPage(Json.Text(t,"url")) && AllowedSocket(Json.Text(t,"webSocketDebuggerUrl")))
                    .Select(t => Json.Text(t,"webSocketDebuggerUrl")).Take(32).ToList();
            }
        }
        internal static bool Ready()
        { try { return Discover().Count > 0; } catch { return false; } }
        internal static bool MainPage(string url)
        { Uri uri; return Uri.TryCreate(url, UriKind.Absolute, out uri) && uri.Scheme == "app" && uri.Host == "-" && uri.AbsolutePath == "/index.html" && Uri.UnescapeDataString(url).IndexOf("overlay", StringComparison.OrdinalIgnoreCase) < 0; }
        internal static Dictionary<string,object> Evaluate(string endpoint, string expression)
        {
            if (!AllowedSocket(endpoint)) throw new IOException();
            using (ClientWebSocket socket = new ClientWebSocket())
            using (CancellationTokenSource timeout = new CancellationTokenSource(3000))
            {
                socket.Options.Proxy = null;
                socket.ConnectAsync(new Uri(endpoint), timeout.Token).GetAwaiter().GetResult();
                byte[] request = Encoding.UTF8.GetBytes(Json.Write(new { id = 1, method = "Runtime.evaluate", @params = new { expression = expression, returnByValue = true } }));
                socket.SendAsync(new ArraySegment<byte>(request), WebSocketMessageType.Text, true, timeout.Token).GetAwaiter().GetResult();
                byte[] buffer = new byte[8192];
                for (int messages = 0; messages < 100; messages++)
                {
                    using (MemoryStream content = new MemoryStream())
                    {
                        WebSocketReceiveResult frame;
                        do {
                            frame = socket.ReceiveAsync(new ArraySegment<byte>(buffer), timeout.Token).GetAwaiter().GetResult();
                            if (frame.MessageType != WebSocketMessageType.Text || content.Length + frame.Count > 1000000) throw new IOException();
                            content.Write(buffer,0,frame.Count);
                        } while (!frame.EndOfMessage);
                        Dictionary<string, object> result = Json.Read(Encoding.UTF8.GetString(content.ToArray()));
                        if (Json.Number(result,"id") != 1) continue;
                        Dictionary<string,object> body = Json.Map(Json.Get(result,"result"));
                        if (body == null || Json.Get(body,"exceptionDetails") != null) throw new IOException();
                        return Json.Map(Json.Get(Json.Map(Json.Get(body,"result")),"value"));
                    }
                }
                throw new IOException();
            }
        }
        void Run()
        {
            bool wasEnabled = false; string script = Script();
            do {
                bool active; string data;
                lock(sync) { active = enabled; data = payload; }
                if (stop.WaitOne(0)) active = false;
                if (active || wasEnabled)
                {
                    try {
                        List<string> endpoints = Discover(); bool mounted = false;
                        foreach (string endpoint in endpoints)
                        {
                            string expression = active && data != null ? script + ";window.__petsPetWindowsQuotaV1.configure(" + data + ")" : "({removed:window.__petsPetWindowsQuotaV1?.destroy()??true})";
                            Dictionary<string,object> result = Evaluate(endpoint, expression);
                            mounted |= Object.Equals(Json.Get(result,"mounted"), true);
                        }
                        StatusText(active ? mounted ? "头像上方竖向双环 · 已连接" : "头像隐藏或空间不足 · 等待恢复" : "侧栏已断开");
                    }
                    catch { StatusText(active ? "侧栏未连接 · 托盘菜单可启用连接" : "侧栏已断开"); }
                }
                wasEnabled = active;
                if (stop.WaitOne(2000))
                {
                    if (wasEnabled) { lock(sync) enabled = false; continue; }
                    break;
                }
            } while (true);
        }
        public static string RenderPayload(QuotaSnapshot snapshot, string error, string mode, string appearance, int zoom)
        {
            Func<string,string> render = theme => {
                using (Bitmap bitmap = Art.Widget(snapshot,error,false,mode,Palette.For(theme),"", 2f * zoom/100f, DateTime.UtcNow, true))
                using (MemoryStream stream = new MemoryStream()) { bitmap.Save(stream, ImageFormat.Png); return "data:image/png;base64," + Convert.ToBase64String(stream.ToArray()); }
            };
            return Json.Write(new { light=render("light"), dark=render("dark"), appearance=appearance, width=Art.Height*zoom/100.0, height=Art.Width*zoom/100.0 });
        }
        public void Dispose() { lock(sync) enabled = false; stop.Set(); }
    }
}
