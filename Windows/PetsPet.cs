// Windows companion inspired by https://github.com/Marwin-M/pets-pet.
// This is an independent native implementation. It never patches Codex.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Windows.Forms;
using Microsoft.Win32;

namespace PetsPetWindows
{
    static class Json
    {
        public static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object>; }
        public static object Get(Dictionary<string, object> map, string key)
        { object value; return map != null && map.TryGetValue(key, out value) ? value : null; }
        public static string Text(Dictionary<string, object> map, string key) { return Get(map, key) as string; }
        public static double? Number(Dictionary<string, object> map, string key)
        {
            object value = Get(map, key);
            if (!(value is int || value is long || value is double || value is decimal)) return null;
            double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
            return double.IsNaN(number) || double.IsInfinity(number) ? (double?)null : number;
        }
        public static string Write(object value) { return new JavaScriptSerializer().Serialize(value); }
        public static Dictionary<string, object> Read(string value)
        { return new JavaScriptSerializer { MaxJsonLength = 2000000 }.DeserializeObject(value) as Dictionary<string, object>; }
    }

    sealed class Settings
    {
        public string Theme = "system", Mode = "automatic", Position = "followPet", CodexHome, CodexExecutable;
        public bool Follow = true, Passthrough = false;
        public int X = int.MinValue, Y = int.MinValue, Zoom = 100;
        public static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
        public static readonly string Data = Path.Combine(Root, "data");
        static readonly string FilePath = Path.Combine(Data, "settings.json");
        public static Settings Load()
        {
            Settings settings = new Settings();
            settings.CodexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (String.IsNullOrWhiteSpace(settings.CodexHome))
            {
                settings.CodexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            }
            try
            {
                if (!File.Exists(FilePath)) return settings;
                Dictionary<string, object> json = Json.Read(File.ReadAllText(FilePath, Encoding.UTF8));
                string theme = Json.Text(json, "theme"), mode = Json.Text(json, "mode"), home = Json.Text(json, "codexHome");
                if (new[] { "system", "light", "dark" }.Contains(theme)) settings.Theme = theme;
                if (new[] { "automatic", "quota", "countdown" }.Contains(mode)) settings.Mode = mode;
                if (!String.IsNullOrWhiteSpace(home) && Path.IsPathRooted(home)) settings.CodexHome = home;
                object follow = Json.Get(json, "follow");
                if (follow is bool) settings.Follow = (bool)follow;
                string position = Json.Text(json, "position");
                settings.Position = new[] { "followPet", "sidebarBottom", "floating" }.Contains(position) ? position : settings.Follow ? "followPet" : "floating";
                settings.Follow = settings.Position == "followPet";
                object passthrough = Json.Get(json, "passthrough");
                if (passthrough is bool) settings.Passthrough = (bool)passthrough;
                string executable = Json.Text(json, "codexExecutable");
                if (SidebarLauncher.IsCodexExecutable(executable)) settings.CodexExecutable = executable;
                double? zoom = Json.Number(json, "zoom");
                if (zoom.HasValue) settings.Zoom = ClampZoom((int)Math.Max(50, Math.Min(200, zoom.Value)));
                double? x = Json.Number(json, "x"), y = Json.Number(json, "y");
                if (x.HasValue && y.HasValue && x > -100000 && x < 100000 && y > -100000 && y < 100000)
                { settings.X = (int)x; settings.Y = (int)y; }
            }
            catch { /* Invalid settings must not prevent startup. */ }
            return settings;
        }
        public bool Save()
        {
            try
            {
                Directory.CreateDirectory(Data);
                string temporary = FilePath + ".tmp";
                File.WriteAllText(temporary, Json.Write(new { theme = Theme, mode = Mode, position = Position, follow = Follow, passthrough = Passthrough, x = X, y = Y, zoom = Zoom, codexHome = CodexHome, codexExecutable = CodexExecutable }), new UTF8Encoding(false));
                if (File.Exists(FilePath)) File.Replace(temporary, FilePath, null); else File.Move(temporary, FilePath);
                return true;
            }
            catch { return false; }
        }
        public static int ClampZoom(int value) { return Math.Max(50, Math.Min(200, value)); }
        public static string ResolveMode(string mode, QuotaSnapshot snapshot)
        { return mode == "automatic" ? snapshot != null && snapshot.FiveHour == null && snapshot.Weekly != null ? "countdown" : "quota" : mode; }
    }

    sealed class QuotaWindow
    {
        public double? Used, Reset;
        public int Minutes;
        public static QuotaWindow Parse(object value)
        {
            Dictionary<string, object> map = Json.Map(value);
            if (map == null) return null;
            double? minutes = Json.Number(map, "windowDurationMins");
            return new QuotaWindow { Used = Json.Number(map, "usedPercent"), Reset = Json.Number(map, "resetsAt"), Minutes = minutes.HasValue && minutes > 0 && minutes <= 525600 ? (int)minutes : 0 };
        }
        public int? Remaining(double now)
        {
            if (!Used.HasValue || (Reset.HasValue && Reset <= now)) return null;
            return (int)Math.Round(100 - Math.Min(100, Math.Max(0, Used.Value)), MidpointRounding.AwayFromZero);
        }
        public double? Seconds(double now)
        {
            if (!Reset.HasValue || Minutes <= 0) return null;
            double seconds = Reset.Value - now;
            return seconds > 0 && seconds <= Minutes * 60.0 ? (double?)seconds : null;
        }
        public string ResetText()
        {
            try { return Reset.HasValue ? Time.Epoch.AddSeconds(Reset.Value).ToLocalTime().ToString("M月d日 HH:mm", CultureInfo.InvariantCulture) : "官方未提供"; }
            catch { return "官方未提供"; }
        }
    }

    sealed class QuotaSnapshot
    {
        public QuotaWindow FiveHour, Weekly;
        public DateTime FetchedUtc;
        public string Plan;
        public static QuotaSnapshot Parse(Dictionary<string, object> result, DateTime now)
        {
            Dictionary<string, object> bucket;
            Dictionary<string, object> buckets = Json.Map(Json.Get(result, "rateLimitsByLimitId"));
            if (buckets != null && buckets.Count > 0) bucket = Json.Map(Json.Get(buckets, "codex"));
            else bucket = Json.Map(Json.Get(result, "rateLimits"));
            if (bucket == null || (Json.Text(bucket, "limitId") != null && Json.Text(bucket, "limitId") != "codex"))
                throw new QueryException("这个账号未提供明确的 Codex 额度，请在 Codex 中检查登录状态。");
            QuotaWindow[] windows = { QuotaWindow.Parse(Json.Get(bucket, "primary")), QuotaWindow.Parse(Json.Get(bucket, "secondary")) };
            QuotaSnapshot snapshot = new QuotaSnapshot { FetchedUtc = now, Plan = Json.Text(bucket, "planType") };
            snapshot.FiveHour = windows.FirstOrDefault(w => w != null && w.Minutes == 300);
            snapshot.Weekly = windows.FirstOrDefault(w => w != null && w.Minutes == 10080);
            if (snapshot.FiveHour == null && snapshot.Weekly == null) throw new QueryException("官方暂未提供 5 小时或每周额度。");
            return snapshot;
        }
        public bool Fresh(DateTime now) { double age = (now - FetchedUtc).TotalSeconds; return age >= -5 && age < 150; }
    }

    static class Time
    {
        public static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        public static double Unix(DateTime value) { return (value.ToUniversalTime() - Epoch).TotalSeconds; }
        public static string Duration(double? seconds)
        {
            if (!seconds.HasValue || seconds <= 0) return "等待更新";
            int minutes = Math.Max(1, (int)Math.Ceiling(seconds.Value / 60));
            if (minutes >= 1440) return String.Format("{0}天{1}小时", minutes / 1440, minutes % 1440 / 60);
            if (minutes >= 60) return String.Format("{0}小时{1}分", minutes / 60, minutes % 60);
            return minutes + "分钟";
        }
    }

    sealed class QueryException : Exception { public QueryException(string message) : base(message) { } }

    sealed class QuotaService : IDisposable
    {
        readonly object sync = new object();
        readonly string home;
        Process active;
        bool disposed;
        public QuotaService(string codexHome) { home = codexHome; }
        public static string FindExecutable()
        {
            string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "Codex", "bin");
            foreach (Process process in Process.GetProcessesByName("codex"))
            {
                using (process)
                {
                    try
                    {
                        string path = process.MainModule.FileName;
                        if (path.StartsWith(local + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && File.Exists(path)) return path;
                    }
                    catch { }
                }
            }
            if (Directory.Exists(local))
            {
                foreach (string folder in Directory.GetDirectories(local).OrderByDescending(Directory.GetLastWriteTimeUtc))
                {
                    string candidate = Path.Combine(folder, "codex.exe");
                    if (File.Exists(candidate)) return candidate;
                }
            }
            throw new QueryException("未找到 Codex 自带的服务组件。请先安装并打开 Codex。");
        }
        public QuotaSnapshot Fetch()
        {
            string executable = FindExecutable();
            ProcessStartInfo start = new ProcessStartInfo(executable, "app-server --listen stdio:// -c analytics.enabled=false");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.WorkingDirectory = Path.GetTempPath();
            start.RedirectStandardInput = start.RedirectStandardOutput = start.RedirectStandardError = true;
            start.StandardOutputEncoding = Encoding.UTF8;
            start.StandardErrorEncoding = Encoding.UTF8;
            start.EnvironmentVariables["CODEX_HOME"] = home;
            using (Process process = new Process { StartInfo = start })
            {
                bool timeout = false;
                lock (sync)
                {
                    if (disposed) throw new OperationCanceledException();
                    process.Start(); active = process;
                }
                // Stderr can contain account metadata. Drain and discard it; never log it.
                process.ErrorDataReceived += delegate { };
                process.BeginErrorReadLine();
                using (System.Threading.Timer guard = new System.Threading.Timer(delegate
                {
                    timeout = true;
                    lock (sync) { try { if (!process.HasExited) process.Kill(); } catch { } }
                }, null, 22000, Timeout.Infinite))
                {
                    try
                    {
                        Send(process, new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "pets_pet_windows", title = "PetsPet Windows", version = "1.6.0" } } });
                        int lines = 0; string accountPlan = null; bool accountReceived = false; QuotaSnapshot quota = null;
                        while (lines++ < 10000)
                        {
                            Task<string> read = process.StandardOutput.ReadLineAsync();
                            if (quota != null && !read.Wait(1500)) return quota;
                            string line = read.GetAwaiter().GetResult();
                            if (line == null) break;
                            if (line.Length > 2000000) throw new QueryException("Codex 返回的数据过大，请稍后再试。");
                            Dictionary<string, object> message;
                            try { message = Json.Read(line); } catch { continue; }
                            double? id = Json.Number(message, "id");
                            if (id != 1 && id != 2 && id != 3) continue;
                            Dictionary<string, object> error = Json.Map(Json.Get(message, "error"));
                            if (error != null)
                            {
                                if (id == 3) { accountReceived = true; if (quota != null) return quota; continue; }
                                string raw = (Json.Text(error, "message") ?? "").ToLowerInvariant();
                                bool auth = new[] { "auth", "login", "chatgpt", "credential" }.Any(raw.Contains);
                                throw new QueryException(auth ? "请先在 Codex 中登录支持额度查询的 ChatGPT 账号。" : "官方额度服务暂时不可用，请稍后刷新。");
                            }
                            if (id == 1)
                            {
                                if (Json.Map(Json.Get(message, "result")) == null) throw new QueryException("Codex 服务初始化失败，请更新 Codex 后重试。");
                                Send(process, new { method = "initialized", @params = new { } });
                                Send(process, new { id = 3, method = "account/read", @params = new { refreshToken = false } });
                                Send(process, new { id = 2, method = "account/rateLimits/read" });
                            }
                            else if (id == 3)
                            {
                                accountReceived = true;
                                accountPlan = AccountPlan(Json.Map(Json.Get(message, "result")));
                                if (quota != null) { if (String.IsNullOrEmpty(quota.Plan)) quota.Plan = accountPlan; return quota; }
                            }
                            else
                            {
                                quota = QuotaSnapshot.Parse(Json.Map(Json.Get(message, "result")), DateTime.UtcNow);
                                if (String.IsNullOrEmpty(quota.Plan)) quota.Plan = accountPlan;
                                if (accountReceived || !String.IsNullOrEmpty(quota.Plan)) return quota;
                            }
                        }
                        if (quota != null) return quota;
                        throw new QueryException(timeout ? "额度查询超时，请检查网络后刷新。" : "Codex 额度服务已结束，请稍后刷新。");
                    }
                    finally
                    {
                        guard.Change(Timeout.Infinite, Timeout.Infinite);
                        lock (sync)
                        {
                            try { process.StandardInput.Close(); } catch { }
                            try { if (!process.WaitForExit(500)) { process.Kill(); process.WaitForExit(1000); } } catch { }
                            if (active == process) active = null;
                        }
                    }
                }
            }
        }
        static void Send(Process process, object value) { process.StandardInput.WriteLine(Json.Write(value)); process.StandardInput.Flush(); }
        internal static string AccountPlan(Dictionary<string, object> result)
        { return Json.Text(Json.Map(Json.Get(result, "account")), "planType"); }
        public void CancelCurrent()
        { lock (sync) { try { if (active != null && !active.HasExited) active.Kill(); } catch { } } }
        public void Dispose()
        {
            lock (sync)
            {
                disposed = true;
                try { if (active != null && !active.HasExited) active.Kill(); } catch { }
            }
        }
    }

    sealed class PetAnchor
    {
        public Rectangle Pet, Occupied;
        public IntPtr Window;
        public string Status;
        public bool Found { get { return !Pet.IsEmpty; } }
    }

    sealed class PetTracker : IDisposable
    {
        readonly object sync = new object();
        readonly ManualResetEvent stop = new ManualResetEvent(false);
        PetAnchor latest = new PetAnchor { Status = "正在寻找宠物…" };
        public volatile bool Enabled = true;
        long fastUntil;
        int reset;
        public bool Fast { get { return Stopwatch.GetTimestamp() < Interlocked.Read(ref fastUntil); } }
        public void WakeMotion() { Interlocked.Exchange(ref fastUntil, Stopwatch.GetTimestamp() + Stopwatch.Frequency / 5); }
        public void Rescan() { Publish(new PetAnchor { Status = "正在重新寻找宠物…" }); Interlocked.Exchange(ref reset, 1); }
        public PetAnchor Current { get { lock (sync) return latest; } }
        void Publish(PetAnchor value) { lock (sync) latest = value; }
        public void Start()
        {
            Thread thread = new Thread(Run) { IsBackground = true, Name = "PetsPet pet tracker" };
            thread.SetApartmentState(ApartmentState.MTA); thread.Start();
        }
        public static bool Identity(string identifier, string label)
        {
            if (identifier == "avatar-mascot-button") return true;
            string text = (label ?? "").Trim().ToLowerInvariant();
            return text.Length < 150 && (text.EndsWith(" pet", StringComparison.Ordinal) || text.EndsWith(" 虚拟宠物", StringComparison.Ordinal) || text.EndsWith(" 虛擬寵物", StringComparison.Ordinal));
        }
        static bool PetType(ControlType type)
        { return type == ControlType.Button || type == ControlType.Image || type == ControlType.Group || type == ControlType.Custom; }
        static Rectangle Bounds(AutomationElement element)
        {
            System.Windows.Rect rect = element.Current.BoundingRectangle;
            if (rect.IsEmpty || double.IsInfinity(rect.X) || double.IsNaN(rect.X) || rect.Width <= 0 || rect.Height <= 0) return Rectangle.Empty;
            return Rectangle.Round(new RectangleF((float)rect.X, (float)rect.Y, (float)rect.Width, (float)rect.Height));
        }
        static bool Valid(Rectangle rect) { return rect.Width >= 16 && rect.Width <= 260 && rect.Height >= 16 && rect.Height <= 300; }
        public static PetAnchor Scan(out AutomationElement target)
        {
            target = null;
            List<IntPtr> windows = Native.CodexWindows();
            if (windows.Count == 0) return new PetAnchor { Status = "Codex 未运行或没有可见窗口" };
            List<Tuple<AutomationElement, PetAnchor>> matches = new List<Tuple<AutomationElement, PetAnchor>>();
            foreach (IntPtr window in windows.OrderBy(w => Native.WindowBounds(w).Width))
            {
                try
                {
                    AutomationElement root = AutomationElement.FromHandle(window);
                    Queue<AutomationElement> queue = new Queue<AutomationElement>(); queue.Enqueue(root);
                    List<Rectangle> controls = new List<Rectangle>();
                    Stopwatch timer = Stopwatch.StartNew();
                    int nodes = 0;
                    while (queue.Count > 0 && nodes++ < 650 && timer.ElapsedMilliseconds < 600)
                    {
                        AutomationElement node = queue.Dequeue();
                        try
                        {
                            if (node.Current.IsOffscreen) continue;
                            ControlType type = node.Current.ControlType;
                            Rectangle rect = Rectangle.Empty;
                            // Never read a chat text node's Name or Value.
                            if (PetType(type))
                            {
                                string identifier = node.Current.AutomationId;
                                string name = node.Current.Name;
                                rect = Bounds(node);
                                if (Identity(identifier, name) && Valid(rect) && Native.WindowBounds(window).IntersectsWith(rect))
                                    matches.Add(Tuple.Create(node, new PetAnchor { Window = window, Pet = rect, Occupied = rect, Status = "正在跟随宠物" }));
                            }
                            if (type == ControlType.Button || type == ControlType.Text) { if (rect.IsEmpty) rect = Bounds(node); if (!rect.IsEmpty) controls.Add(rect); }
                            AutomationElement child = TreeWalker.ControlViewWalker.GetFirstChild(node);
                            int siblings = 0;
                            while (child != null && siblings++ < 150 && queue.Count < 650)
                            { queue.Enqueue(child); child = TreeWalker.ControlViewWalker.GetNextSibling(child); }
                        }
                        catch (ElementNotAvailableException) { }
                        catch (InvalidOperationException) { }
                    }
                    Rectangle windowRect = Native.WindowBounds(window);
                    if (windowRect.Width <= 750 && windowRect.Height <= 800)
                    {
                        foreach (Tuple<AutomationElement, PetAnchor> match in matches.Where(m => m.Item2.Window == window))
                        {
                            Rectangle nearby = Rectangle.Inflate(match.Item2.Pet, 150, 240);
                            foreach (Rectangle control in controls.Where(r => r.Width < 700 && r.Height < 500 && nearby.IntersectsWith(r)))
                                match.Item2.Occupied = Rectangle.Union(match.Item2.Occupied, control);
                        }
                    }
                }
                catch { /* Replaced/closed windows are retried on the next scan. */ }
            }
            if (matches.Count != 1) return new PetAnchor { Status = matches.Count > 1 ? "发现多个宠物，暂用独立浮窗" : "未找到显示中的宠物" };
            target = matches[0].Item1; return matches[0].Item2;
        }
        void Run()
        {
            AutomationElement target = null;
            PetAnchor previous = null;
            DateTime nextScan = DateTime.MinValue;
            while (!stop.WaitOne(Fast ? 16 : 200))
            {
                if (Interlocked.Exchange(ref reset, 0) != 0) { target = null; previous = null; nextScan = DateTime.MinValue; }
                if (!Enabled) { target = null; previous = null; nextScan = DateTime.MinValue; continue; }
                if (target != null && previous != null)
                {
                    try
                    {
                        Rectangle rect = Bounds(target);
                        if (!Native.IsWindowVisible(previous.Window) || Native.IsIconic(previous.Window) || target.Current.IsOffscreen || !Valid(rect) || !Native.WindowBounds(previous.Window).IntersectsWith(rect))
                            throw new ElementNotAvailableException();
                        Rectangle occupied = previous.Occupied;
                        occupied.Offset(rect.X - previous.Pet.X, rect.Y - previous.Pet.Y);
                        previous = new PetAnchor { Pet = rect, Occupied = occupied, Window = previous.Window, Status = "正在跟随宠物" };
                        Publish(previous);
                    }
                    catch { target = null; previous = null; nextScan = DateTime.MinValue; Publish(new PetAnchor { Status = "宠物已隐藏，暂用独立浮窗" }); }
                }
                if ((target == null || !Fast) && DateTime.UtcNow >= nextScan)
                {
                    PetAnchor anchor = Scan(out target);
                    previous = anchor.Found ? anchor : null;
                    Publish(anchor); nextScan = DateTime.UtcNow.AddSeconds(anchor.Found ? 8 : 4);
                }
            }
        }
        public void Dispose() { stop.Set(); }
    }

    static class Placement
    {
        public static Rectangle Clamp(Rectangle desired, Rectangle work)
        {
            int x = Math.Max(work.Left + 6, Math.Min(desired.Left, work.Right - desired.Width - 6));
            int y = Math.Max(work.Top + 6, Math.Min(desired.Top, work.Bottom - desired.Height - 6));
            return new Rectangle(x, y, desired.Width, desired.Height);
        }
        public static Rectangle? Follow(Rectangle pet, Rectangle occupied, Size size, Rectangle work)
        {
            if (pet.IsEmpty || work.Width < size.Width + 12 || work.Height < size.Height + 12) return null;
            Rectangle all = Rectangle.Union(pet, occupied);
            Rectangle[] candidates = {
                new Rectangle(pet.X + pet.Width / 2 - size.Width / 2, all.Top - size.Height - 8, size.Width, size.Height),
                new Rectangle(pet.X + pet.Width / 2 - size.Width / 2, all.Bottom + 8, size.Width, size.Height),
                new Rectangle(all.Right + 8, pet.Y + pet.Height / 2 - size.Height / 2, size.Width, size.Height),
                new Rectangle(all.Left - size.Width - 8, pet.Y + pet.Height / 2 - size.Height / 2, size.Width, size.Height)
            };
            foreach (Rectangle candidate in candidates)
            {
                Rectangle adjusted = Clamp(candidate, work);
                if (!Rectangle.Inflate(all, 4, 4).IntersectsWith(adjusted) && work.Contains(adjusted)) return adjusted;
            }
            return null;
        }
    }

    sealed class Palette
    {
        public bool Dark;
        public Color Background, Surface, Border, Text, Muted, Track;
        public static readonly Color Green = Color.FromArgb(36, 199, 150), Blue = Color.FromArgb(26, 122, 255);
        public static Palette For(string theme)
        {
            bool dark = theme == "dark";
            if (theme == "system")
            {
                try { using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) dark = key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0; } catch { }
            }
            return dark
                ? new Palette { Dark = true, Background = Color.FromArgb(19, 26, 39), Surface = Color.FromArgb(27, 36, 52), Border = Color.FromArgb(54, 67, 86), Text = Color.FromArgb(238, 244, 252), Muted = Color.FromArgb(157, 174, 196), Track = Color.FromArgb(48, 63, 81) }
                : new Palette { Dark = false, Background = Color.FromArgb(247, 250, 254), Surface = Color.White, Border = Color.FromArgb(221, 229, 239), Text = Color.FromArgb(27, 43, 63), Muted = Color.FromArgb(104, 122, 145), Track = Color.FromArgb(225, 234, 243) };
        }
    }

    sealed class MenuColors : ProfessionalColorTable
    {
        readonly Palette colors;
        public MenuColors(Palette palette) { colors = palette; UseSystemColors = false; }
        Color Selected { get { return colors.Dark ? Color.FromArgb(47, 65, 88) : Color.FromArgb(228, 240, 252); } }
        public override Color ToolStripDropDownBackground { get { return colors.Surface; } }
        public override Color ImageMarginGradientBegin { get { return colors.Surface; } }
        public override Color ImageMarginGradientMiddle { get { return colors.Surface; } }
        public override Color ImageMarginGradientEnd { get { return colors.Surface; } }
        public override Color MenuBorder { get { return colors.Border; } }
        public override Color MenuItemBorder { get { return colors.Border; } }
        public override Color MenuItemSelected { get { return Selected; } }
        public override Color MenuItemSelectedGradientBegin { get { return Selected; } }
        public override Color MenuItemSelectedGradientEnd { get { return Selected; } }
        public override Color MenuItemPressedGradientBegin { get { return Selected; } }
        public override Color MenuItemPressedGradientMiddle { get { return Selected; } }
        public override Color MenuItemPressedGradientEnd { get { return Selected; } }
        public override Color SeparatorDark { get { return colors.Border; } }
        public override Color SeparatorLight { get { return colors.Surface; } }
        public override Color CheckBackground { get { return Selected; } }
        public override Color CheckSelectedBackground { get { return Selected; } }
    }

    sealed class MenuRenderer : ToolStripProfessionalRenderer
    {
        readonly Palette colors;
        public MenuRenderer(Palette palette) : base(new MenuColors(palette)) { colors = palette; RoundedEdges = false; }
        protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) { e.ArrowColor = colors.Text; base.OnRenderArrow(e); }
        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        { e.TextColor = e.Item.Enabled ? colors.Text : colors.Muted; base.OnRenderItemText(e); }
    }

    static class Art
    {
        // Original body, rings and waist proportions; custom size scales both axes together.
        public const int Width = 128, Height = 64;
        public static GraphicsPath Rounded(RectangleF r, float radius)
        {
            GraphicsPath path = new GraphicsPath(); float d = radius * 2;
            path.AddArc(r.Left, r.Top, d, d, 180, 90); path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
        }
        public static void Text(Graphics g, string value, float x, float y, float size, Color color, bool bold, bool center, bool vertical = false)
        {
            using (Font font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel))
            using (SolidBrush brush = new SolidBrush(color))
            using (StringFormat format = new StringFormat(StringFormat.GenericTypographic))
            {
                format.Alignment = center ? StringAlignment.Center : StringAlignment.Near;
                format.LineAlignment = StringAlignment.Center;
                format.FormatFlags |= StringFormatFlags.NoWrap;
                if (vertical) {
                    GraphicsState saved = g.Save();
                    try { g.TranslateTransform(x,y); g.RotateTransform(-90); g.DrawString(value,font,brush,PointF.Empty,format); }
                    finally { g.Restore(saved); }
                } else g.DrawString(value, font, brush, new PointF(x, y), format);
            }
        }
        public static Bitmap Widget(QuotaSnapshot snapshot, string error, bool loading, string mode, Palette colors, string connection, float scale, DateTime now, bool vertical = false)
        {
            Bitmap bitmap = new Bitmap((int)Math.Round((vertical ? Height : Width) * scale), (int)Math.Round((vertical ? Width : Height) * scale), PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(bitmap))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.ScaleTransform(scale, scale);
                if (vertical) { g.TranslateTransform(Height,0); g.RotateTransform(90); }
                bool fresh = error == null && snapshot != null && snapshot.Fresh(now);
                double epoch = Time.Unix(now);
                bool countdown = Settings.ResolveMode(mode, snapshot) == "countdown";
                using (GraphicsPath shape = Capsule(new RectangleF(.8f, .8f, 126.4f, 62.4f)))
                {
                    GraphicsState state = g.Save(); g.SetClip(shape);
                    // The same quiet base, tint and subtle rim as upstream; no added glass effects.
                    using (SolidBrush surface = new SolidBrush(colors.Dark ? Color.FromArgb(224, 18, 26, 41) : Color.FromArgb(153, Color.White)))
                        g.FillPath(surface, shape);
                    using (LinearGradientBrush tint = new LinearGradientBrush(new PointF(0, 0), new PointF(Width, 0), Color.FromArgb(colors.Dark ? 13 : 56, 171, 214, 224), Color.FromArgb(colors.Dark ? 31 : 59, 94, 148, 255)))
                        g.FillPath(tint, shape);
                    using (LinearGradientBrush shine = new LinearGradientBrush(new PointF(0, 0), new PointF(0, Height), Color.White, Color.FromArgb(0, Color.White)))
                    {
                        shine.InterpolationColors = new ColorBlend { Positions = new[] { 0f, .5f, 1f }, Colors = new[] { Color.FromArgb(colors.Dark ? 20 : 51, Color.White), Color.FromArgb(0, Color.White), Color.FromArgb(0, Color.White) } };
                        g.FillPath(shine, shape);
                    }
                    using (GraphicsPath body = InfinityBase())
                    using (LinearGradientBrush shade = new LinearGradientBrush(new PointF(0, 0), new PointF(Width, 0), Color.FromArgb(36, Color.White), Color.FromArgb(20, Color.Black)))
                        g.FillPath(shade, body);
                    if (snapshot != null && String.Equals(snapshot.Plan, "pro", StringComparison.OrdinalIgnoreCase))
                        Text(g, "PRO", 64, 32, 10f, Color.FromArgb(colors.Dark ? 89 : 71, colors.Dark ? Color.Black : Color.White), true, true, vertical);
                    DrawConnection(g, colors);
                    QuotaWindow weekly = snapshot == null ? null : snapshot.Weekly;
                    QuotaWindow left = snapshot == null ? null : countdown ? weekly : snapshot.FiveHour;
                    Ring(g, 31, 32, left, fresh, countdown, countdown ? Palette.Blue : Palette.Green, colors, epoch, false, vertical);
                    Ring(g, 97, 32, weekly, fresh, false, countdown ? Palette.Green : Palette.Blue, colors, epoch, true, vertical);
                    Text(g, countdown ? "D" : "5H", 64, 11, 9.5f, colors.Muted, false, true, vertical);
                    Text(g, "W", 64, 53, 9.5f, colors.Muted, false, true, vertical);
                    g.Restore(state);
                    using (LinearGradientBrush rim = new LinearGradientBrush(new PointF(0, 0), new PointF(Width, Height), Color.FromArgb(colors.Dark ? 71 : 184, Color.White), Color.FromArgb(colors.Dark ? 20 : 46, Color.White)))
                    using (Pen edge = new Pen(rim, .8f)) g.DrawPath(edge, shape);
                }
            }
            return bitmap;
        }
        static GraphicsPath Capsule(RectangleF r)
        {
            float radius = r.Height / 2, left = r.Left + radius, right = r.Right - radius;
            float waist = r.Height * 1.8f / 64, k = .55228475f, arc = radius * k;
            float curvature = 2 * (1 - k) / (3 * radius * k * k);
            float shoulder = (float)Math.Sqrt(2 * waist / (3 * curvature)), center = (r.X + r.Width / 2 - left) * .38f;
            float midX = r.X + r.Width / 2, midY = r.Y + r.Height / 2;
            GraphicsPath path = new GraphicsPath();
            path.AddBezier(left, r.Top, left + shoulder, r.Top, midX - center, r.Top + waist, midX, r.Top + waist);
            path.AddBezier(midX, r.Top + waist, midX + center, r.Top + waist, right - shoulder, r.Top, right, r.Top);
            path.AddBezier(right, r.Top, right + arc, r.Top, r.Right, midY - arc, r.Right, midY);
            path.AddBezier(r.Right, midY, r.Right, midY + arc, right + arc, r.Bottom, right, r.Bottom);
            path.AddBezier(right, r.Bottom, right - shoulder, r.Bottom, midX + center, r.Bottom - waist, midX, r.Bottom - waist);
            path.AddBezier(midX, r.Bottom - waist, midX - center, r.Bottom - waist, left + shoulder, r.Bottom, left, r.Bottom);
            path.AddBezier(left, r.Bottom, left - arc, r.Bottom, r.Left, midY + arc, r.Left, midY);
            path.AddBezier(r.Left, midY, r.Left, midY - arc, left - arc, r.Top, left, r.Top);
            path.CloseFigure(); return path;
        }
        static GraphicsPath InfinityBase()
        {
            const float radius = 22, angle = 55;
            float x = radius * (float)Math.Cos(angle * Math.PI / 180), y = radius * (float)Math.Sin(angle * Math.PI / 180);
            float leftX = 31 + x, rightX = 97 - x, handle = (rightX - leftX) * .34f;
            float dx = handle * (float)Math.Sin(angle * Math.PI / 180), dy = handle * (float)Math.Cos(angle * Math.PI / 180);
            GraphicsPath path = new GraphicsPath();
            path.AddArc(9, 10, 44, 44, -55, -250);
            path.AddBezier(leftX, 32 + y, leftX + dx, 32 + y - dy, rightX - dx, 32 + y - dy, rightX, 32 + y);
            path.AddArc(75, 10, 44, 44, 125, -250);
            path.AddBezier(rightX, 32 - y, rightX - dx, 32 - y + dy, leftX + dx, 32 - y + dy, leftX, 32 - y);
            path.CloseFigure(); return path;
        }
        static float CurveParameter(float target)
        {
            float low = 0, high = 1;
            for (int i = 0; i < 32; i++)
            {
                float t = (low + high) / 2, u = 1 - t;
                float x = 3 * u * u * t * (43.7f / 78) + 3 * u * t * t * (32.545f / 78) + t * t * t;
                if (x < target) low = t; else high = t;
            }
            return (low + high) / 2;
        }
        static void DrawConnection(Graphics g, Palette colors)
        {
            float angle = 55 * (float)Math.PI / 180, capY = 22 * (float)Math.Sin(angle);
            float capX = 22 * (float)Math.Cos(angle) / 66;
            float l = CurveParameter(capX), r = CurveParameter(1 - capX);
            float weightL = l * l * (3 - 2 * l), weightR = r * r * (3 - 2 * r);
            float height = 2 * capY / (weightR - weightL), bottom = 32 + capY + height * weightL, top = bottom - height;
            using (GraphicsPath curve = new GraphicsPath())
            using (LinearGradientBrush highlight = new LinearGradientBrush(new PointF(64, top), new PointF(64, bottom), Color.Transparent, Color.Transparent))
            {
                highlight.InterpolationColors = new ColorBlend { Positions = new[] { 0f, .18f, .5f, .82f, 1f }, Colors = new[] { Color.FromArgb(0, Color.White), Color.FromArgb(60, Color.White), Color.FromArgb(117, Color.White), Color.FromArgb(60, Color.White), Color.FromArgb(0, Color.White) } };
                curve.AddBezier(31, bottom, 31 + 66 * (43.7f / 78), bottom, 31 + 66 * (32.545f / 78), top, 97, top);
                using (Pen pen = new Pen(highlight, 1.7f)) g.DrawPath(pen, curve);
            }
        }
        static void Ring(Graphics g, float x, float y, QuotaWindow window, bool fresh, bool countdown, Color accent, Palette colors, double now, bool weekly, bool vertical)
        {
            RectangleF ring = new RectangleF(x - 22, y - 22, 44, 44);
            string number = "--";
            float fraction = 0;
            if (fresh && window != null)
            {
                int? remaining = window.Remaining(now);
                if (!countdown && remaining.HasValue) { number = remaining.Value.ToString(CultureInfo.InvariantCulture); fraction = remaining.Value / 100f; }
                if (countdown)
                {
                    double? seconds = window.Seconds(now);
                    if (seconds.HasValue)
                    {
                        number = Math.Max(.1, seconds.Value / 86400).ToString("0.0", CultureInfo.InvariantCulture);
                        fraction = (float)(1 - seconds.Value / (window.Minutes * 60.0));
                    }
                }
            }
            float start = weekly ? 235 : -55, direction = weekly ? 1 : -1;
            using (Pen track = new Pen(Color.FromArgb(colors.Dark ? 61 : 230, Color.White), 5.5f)) { track.StartCap = track.EndCap = LineCap.Round; g.DrawArc(track, ring, start, 250 * direction); }
            if (fraction > 0)
            {
                using (LinearGradientBrush pigment = new LinearGradientBrush(new PointF(x - 22, y - 22), new PointF(x + 22, y + 22), accent, Color.FromArgb(194, accent)))
                using (Pen progress = new Pen(pigment, 5.5f)) { progress.StartCap = progress.EndCap = LineCap.Round; g.DrawArc(progress, ring, start, Math.Max(.1f, 250 * fraction) * direction); }
            }
            float fontSize = number.Length >= 4 ? 14 : number == "100" ? 16 : 18;
            Text(g, number, x, y, fontSize, colors.Text, true, true, vertical);
        }
    }

    class LayerForm : Form
    {
        public LayerForm()
        {
            FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
            AutoScaleMode = AutoScaleMode.None; StartPosition = FormStartPosition.Manual;
        }
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get { CreateParams value = base.CreateParams; value.ExStyle |= 0x80000 | 0x08000000; return value; }
        }
        public void MouseThrough(bool enabled)
        {
            if (!IsHandleCreated) return;
            long style = Native.GetWindowLongPtr(Handle, -20).ToInt64();
            Native.SetWindowLongPtr(Handle, -20, new IntPtr(enabled ? style | 0x20 : style & ~0x20));
        }
        public void Surface(Bitmap bitmap)
        {
            IntPtr screen = Native.GetDC(IntPtr.Zero), memory = Native.CreateCompatibleDC(screen);
            IntPtr image = bitmap.GetHbitmap(Color.FromArgb(0)), previous = Native.SelectObject(memory, image);
            try
            {
                Native.Point origin = new Native.Point { X = Left, Y = Top }, source = new Native.Point();
                Native.Size dimensions = new Native.Size { Width = bitmap.Width, Height = bitmap.Height };
                Native.Blend blend = new Native.Blend { BlendOp = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
                if (!Native.UpdateLayeredWindow(Handle, screen, ref origin, ref dimensions, memory, ref source, 0, ref blend, 2))
                    throw new InvalidOperationException("无法显示额度浮窗。");
                Size = bitmap.Size;
            }
            finally { Native.SelectObject(memory, previous); Native.DeleteObject(image); Native.DeleteDC(memory); Native.ReleaseDC(IntPtr.Zero, screen); }
        }
    }

    sealed class Companion : LayerForm
    {
        readonly Settings settings;
        readonly QuotaService service;
        readonly PetTracker tracker = new PetTracker();
        readonly PetMouseMonitor petMouse;
        readonly SidebarClient sidebar = new SidebarClient();
        readonly System.Windows.Forms.Timer tick = new System.Windows.Forms.Timer { Interval = 120 };
        readonly NotifyIcon tray;
        readonly Icon appIcon;
        Icon trayIcon;
        readonly EventWaitHandle showEvent, exitEvent;
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        ToolStripMenuItem refreshItem, followItem, modeItem, showItem, passthroughItem, sidebarItem;
        DetailForm details;
        QuotaSnapshot snapshot;
        string error;
        bool loading, closing, hidden, dragging, moved, petCollapsed, suspended, enablingSidebar, followPlacementAvailable;
        CancellationTokenSource sidebarCancel;
        string sidebarProgress;
        int refreshGeneration;
        DateTime lastSidebar = DateTime.MinValue;
        Point dragOrigin, formOrigin;
        DateTime nextRefresh = DateTime.MinValue, lastPaint = DateTime.MinValue, lastTheme = DateTime.MinValue;
        Palette colors;
        float scale;
        uint renderedDpi;
        string connection = "独立浮窗 · 右键设置";
        string lastConnection;
        readonly bool openDetails;
        public Companion(Settings value, bool withDetails)
        {
            settings = value; openDetails = withDetails; service = new QuotaService(settings.CodexHome);
            string codexExecutable = SidebarLauncher.FindExecutable(settings.CodexExecutable);
            if (codexExecutable != null && codexExecutable != settings.CodexExecutable) { settings.CodexExecutable = codexExecutable; settings.Save(); }
            Text = "PetsPet 额度浮窗"; AccessibleName = "PetsPet Codex 额度浮窗";
            appIcon = OriginalAssets.ApplicationIcon(); Icon = appIcon; colors = Palette.For(settings.Theme);
            petMouse = new PetMouseMonitor(tracker, delegate {
                if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { if (!suspended && settings.Follow) { petCollapsed = !petCollapsed; ApplyVisibility(); } });
            });
            try
            {
                Directory.CreateDirectory(Settings.Data);
                string iconPath = Path.Combine(Settings.Data, "PetsPet.ico");
                using (Stream source = typeof(OriginalAssets).Assembly.GetManifestResourceStream("PetsPet.AppIcon.ico"))
                using (FileStream iconFile = File.Create(iconPath)) source.CopyTo(iconFile);
            }
            catch { /* A missing shortcut icon does not prevent quota display. */ }
            showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\PetsPet.Windows.Show");
            exitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\PetsPet.Windows.Exit");
            scale = Math.Max(1, Native.SystemDpi() / 96f) * settings.Zoom / 100f;
            Size = new Size((int)Math.Round(Art.Width * scale), (int)Math.Round(Art.Height * scale));
            Rectangle work = Screen.PrimaryScreen.WorkingArea;
            Rectangle initial = settings.X == int.MinValue ? new Rectangle(work.Right - Width - 28, work.Bottom - Height - 24, Width, Height) : new Rectangle(settings.X, settings.Y, Width, Height);
            Bounds = Placement.Clamp(initial, Screen.FromRectangle(initial).WorkingArea);
            BuildMenu(); ContextMenuStrip = menu;
            tracker.Enabled = settings.Follow;
            trayIcon = OriginalAssets.TrayIcon();
            tray = new NotifyIcon { Icon = trayIcon, Text = "PetsPet · 正在读取 Codex 额度", ContextMenuStrip = menu, Visible = true };
            tray.MouseClick += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowDetails(); };
            tick.Tick += Tick;
            MouseDown += DragStart; MouseMove += DragMove; MouseUp += DragEnd;
            MouseDoubleClick += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowDetails(); };
            SystemEvents.PowerModeChanged += PowerChanged;
            SystemEvents.DisplaySettingsChanged += DisplaysChanged;
            Shown += delegate { PaintSurface(); tracker.Start(); tick.Start(); RefreshQuota(); if (openDetails) ShowDetails(); };
        }
        public Palette Colors { get { return colors; } }
        public QuotaSnapshot Snapshot { get { return snapshot; } }
        public string Error { get { return error; } }
        public bool Loading { get { return loading; } }
        public string Connection { get { return enablingSidebar && sidebarProgress != null ? sidebarProgress : connection; } }
        public Settings Options { get { return settings; } }
        public bool Fresh { get { return error == null && snapshot != null && snapshot.Fresh(DateTime.UtcNow); } }
        void BuildMenu()
        {
            menu.Font = new Font("Microsoft YaHei UI", 9);
            menu.Items.Add("查看额度详情", null, delegate { ShowDetails(); });
            refreshItem = new ToolStripMenuItem("立即刷新", null, delegate { RefreshQuota(); }); menu.Items.Add(refreshItem);
            menu.Items.Add(new ToolStripSeparator());
            followItem = new ToolStripMenuItem("显示位置");
            string[] positionNames = { "跟随宠物", "头像上方（竖向双环）", "独立浮窗（可拖动）" }, positions = { "followPet", "sidebarBottom", "floating" };
            for (int i = 0; i < positions.Length; i++) {
                string chosen = positions[i]; ToolStripMenuItem item = new ToolStripMenuItem(positionNames[i]) { Tag = chosen };
                item.Click += delegate { SetPosition(chosen); }; followItem.DropDownItems.Add(item);
            }
            menu.Items.Add(followItem);
            sidebarItem = new ToolStripMenuItem("启用侧栏连接…", null, delegate { EnableSidebar(); }); menu.Items.Add(sidebarItem);
            passthroughItem = new ToolStripMenuItem("鼠标穿透（开启后双环不可点击）");
            passthroughItem.Click += delegate { settings.Passthrough = !settings.Passthrough; SaveSettings(); ApplyVisibility(); UpdateDetails(); };
            menu.Items.Add(passthroughItem);
            modeItem = new ToolStripMenuItem("显示内容");
            string[] modeNames = { "自动选择（与原版相同）", "5H / W 剩余额度", "D / W 周重置天数与余量" }, modes = { "automatic", "quota", "countdown" };
            for (int i = 0; i < modes.Length; i++) {
                string chosen = modes[i]; ToolStripMenuItem item = new ToolStripMenuItem(modeNames[i]) { Tag = chosen };
                item.Click += delegate { settings.Mode = chosen; SaveSettings(); PaintSurface(); lastSidebar = DateTime.MinValue; }; modeItem.DropDownItems.Add(item);
            }
            menu.Items.Add(modeItem);
            ToolStripMenuItem appearance = new ToolStripMenuItem("外观");
            string[] names = { "跟随系统", "浅色", "深色" }, values = { "system", "light", "dark" };
            for (int i = 0; i < names.Length; i++)
            {
                string chosen = values[i];
                ToolStripMenuItem item = new ToolStripMenuItem(names[i]) { Tag = chosen, Checked = settings.Theme == chosen };
                item.Click += delegate
                {
                    SetTheme(chosen);
                    foreach (ToolStripMenuItem other in appearance.DropDownItems) other.Checked = (string)other.Tag == chosen;
                };
                appearance.DropDownItems.Add(item);
            }
            menu.Items.Add(appearance);
            menu.Items.Add("自定义浮窗大小…", null, delegate { ShowDetails(); details.FocusSize(); });
            showItem = new ToolStripMenuItem("隐藏组件", null, delegate { hidden = !hidden; petCollapsed = false; ApplyVisibility(); lastSidebar = DateTime.MinValue; showItem.Text = hidden ? "显示组件" : "隐藏组件"; }); menu.Items.Add(showItem);
            menu.Items.Add("保存组件图片", null, delegate { SavePicture(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, delegate { Close(); });
            menu.Opening += delegate
            {
                menu.Renderer = new MenuRenderer(colors);
                appearance.DropDown.Renderer = new MenuRenderer(colors);
                foreach (ToolStripMenuItem item in followItem.DropDownItems) item.Checked = (string)item.Tag == settings.Position;
                foreach (ToolStripMenuItem item in modeItem.DropDownItems) item.Checked = (string)item.Tag == settings.Mode;
                passthroughItem.Enabled = settings.Follow;
                passthroughItem.Checked = settings.Follow && settings.Passthrough;
                followItem.DropDown.Renderer = modeItem.DropDown.Renderer = new MenuRenderer(colors);
                foreach (ToolStripMenuItem item in appearance.DropDownItems) item.Checked = (string)item.Tag == settings.Theme;
            };
        }
        void SetPosition(string position)
        {
            settings.Position = position; settings.Follow = position == "followPet"; petCollapsed = false; hidden = false; followPlacementAvailable = false;
            showItem.Text = "隐藏组件"; tracker.Rescan(); SaveSettings(); lastSidebar = DateTime.MinValue;
            ApplyVisibility(); PaintSurface(); UpdateDetails();
        }
        void ApplyVisibility()
        {
            bool follow = settings.Follow && !suspended;
            tracker.Enabled = follow;
            petMouse.Enable(follow);
            MouseThrough(settings.Follow && settings.Passthrough);
            bool visible = !hidden && !suspended && settings.Position != "sidebarBottom" && (!settings.Follow || FollowVisible(tracker.Current.Found, followPlacementAvailable, petCollapsed));
            if (Visible != visible) { if (visible) Show(); else Hide(); }
        }
        internal static bool FollowVisible(bool petFound, bool placementAvailable, bool collapsed)
        { return petFound && placementAvailable && !collapsed; }
        void PowerChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (closing || !IsHandleCreated) return;
            if (e.Mode == PowerModes.Suspend || e.Mode == PowerModes.Resume)
                BeginInvoke((Action)delegate { SetSuspended(e.Mode == PowerModes.Suspend); });
        }
        internal void SetSuspended(bool value)
        {
            suspended = value; refreshGeneration++; tracker.Rescan();
            if (value && sidebarCancel != null) sidebarCancel.Cancel();
            sidebar.Configure(false, null); lastSidebar = DateTime.MinValue;
            if (value) service.CancelCurrent();
            else { snapshot = null; error = null; nextRefresh = DateTime.MinValue; }
            ApplyVisibility();
        }
        void DisplaysChanged(object sender, EventArgs e)
        {
            if (closing || !IsHandleCreated) return;
            BeginInvoke((Action)delegate {
                tracker.Rescan(); Bounds = Placement.Clamp(Bounds, Screen.FromRectangle(Bounds).WorkingArea);
                PaintSurface(); lastSidebar = DateTime.MinValue;
            });
        }
        internal async void EnableSidebar()
        {
            if (enablingSidebar) { if (sidebarCancel != null) sidebarCancel.Cancel(); return; }
            enablingSidebar = true;
            sidebarProgress = "正在检查侧栏连接…";
            try
            {
                bool ready = await Task.Run(() => SidebarClient.Ready());
                if (closing) return;
                if (ready) { SetPosition("sidebarBottom"); return; }
                string executable = SidebarLauncher.FindExecutable(settings.CodexExecutable);
                if (executable == null) { MessageBox.Show("还没有找到 Codex 的安装位置。请先正常打开一次 Codex，再从这里启用。", "PetsPet"); return; }
                settings.CodexExecutable = executable; SaveSettings();
                if (await Task.Run(() => SidebarLauncher.IsRunning())) {
                    if (!closing) MessageBox.Show("请先手动完全退出 Codex，包括后台进程，再点击本工具的“连接侧栏”。\n\n本工具不会自动关闭任何窗口。退出后不要从普通快捷方式重开 Codex，应从这里打开。", "PetsPet · 侧栏连接", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                if (closing) return;
                if (MessageBox.Show("Codex 已退出。现在带侧栏参数打开并连接？\n\n只使用本机 127.0.0.1:39222，不修改安装文件。以后也请先完全退出 Codex，再通过这里打开。", "PetsPet · 侧栏连接", MessageBoxButtons.OKCancel, MessageBoxIcon.Information) != DialogResult.OK) return;
                sidebarCancel = new CancellationTokenSource();
                sidebarItem.Text = "取消连接检测"; ShowDetails();
                Action<string> progress = text => {
                    if (!closing && IsHandleCreated) BeginInvoke((Action)delegate { sidebarProgress = text; UpdateDetails(); });
                };
                string problem = await Task.Run(() => SidebarLauncher.Open(executable, progress, sidebarCancel.Token));
                if (closing) return;
                if (problem != null) MessageBox.Show(problem, "PetsPet · 侧栏连接", MessageBoxButtons.OK, MessageBoxIcon.Information);
                else SetPosition("sidebarBottom");
            }
            catch (OperationCanceledException) { }
            catch { if (!closing) MessageBox.Show("未能启用侧栏连接。可以继续使用跟随宠物模式。", "PetsPet"); }
            finally {
                enablingSidebar = false; sidebarProgress = null;
                if (sidebarCancel != null) { sidebarCancel.Dispose(); sidebarCancel = null; }
                if (!closing) { sidebarItem.Text = "启用侧栏连接…"; UpdateDetails(); }
            }
        }
        public void SetTheme(string theme)
        {
            settings.Theme = theme; colors = Palette.For(theme); SaveSettings(); PaintSurface(); lastSidebar = DateTime.MinValue;
            if (details != null && !details.IsDisposed) details.ApplyTheme();
        }
        public void SetZoom(int percent)
        {
            percent = Settings.ClampZoom(percent);
            if (settings.Zoom == percent) return;
            Point center = new Point(Left + Width / 2, Top + Height / 2);
            settings.Zoom = percent;
            PaintSurface();
            Location = Placement.Clamp(new Rectangle(center.X - Width / 2, center.Y - Height / 2, Width, Height), Screen.FromPoint(center).WorkingArea).Location;
            if (!settings.Follow) { settings.X = Left; settings.Y = Top; }
            SaveSettings(); UpdateDetails();
        }
        void SaveSettings() { if (!settings.Save() && details != null && !details.IsDisposed) details.Notice("设置暂时无法保存，请检查项目文件夹是否可写。"); }
        public async void RefreshQuota()
        {
            if (loading || closing || suspended) return;
            int generation = refreshGeneration;
            loading = true; refreshItem.Enabled = false; PaintSurface();
            try { QuotaSnapshot result = await Task.Run(() => service.Fetch()); if (generation == refreshGeneration) { snapshot = result; error = null; } }
            catch (OperationCanceledException) { }
            catch (QueryException exception) { if (generation == refreshGeneration) error = exception.Message; }
            catch { if (generation == refreshGeneration) error = "暂时无法读取额度，请检查 Codex 登录状态或网络后刷新。"; }
            finally
            {
                loading = false;
                if (!closing && !IsDisposed)
                {
                    nextRefresh = generation == refreshGeneration ? DateTime.UtcNow.AddSeconds(60) : DateTime.MinValue; refreshItem.Enabled = true;
                    PaintSurface(); UpdateDetails();
                }
            }
        }
        void Tick(object sender, EventArgs args)
        {
            if (exitEvent.WaitOne(0)) { Close(); return; }
            if (showEvent.WaitOne(0)) ShowDetails();
            if (suspended) return;
            DateTime now = DateTime.UtcNow;
            if (!loading && now >= nextRefresh) RefreshQuota();
            if ((now - lastTheme).TotalSeconds >= 5)
            {
                lastTheme = now;
                Palette next = Palette.For(settings.Theme);
                Icon nextIcon = OriginalAssets.TrayIcon(); tray.Icon = nextIcon; trayIcon.Dispose(); trayIcon = nextIcon;
                if (next.Dark != colors.Dark) { colors = next; if (details != null && !details.IsDisposed) details.ApplyTheme(); PaintSurface(); }
            }
            PetAnchor anchor = tracker.Current;
            tick.Interval = tracker.Fast && settings.Follow ? 16 : 120;
            if (settings.Follow && anchor.Found && !dragging)
            {
                Rectangle? target = Placement.Follow(anchor.Pet, anchor.Occupied, Size, Screen.FromRectangle(anchor.Pet).WorkingArea);
                followPlacementAvailable = target.HasValue;
                connection = target.HasValue ? (petMouse.Available ? "已跟随宠物 · " + (settings.Passthrough ? "鼠标穿透；设置请点托盘" : "双环可右键设置、双击详情") : "已跟随宠物 · 点击监听不可用，请重开本工具") : "宠物附近空间不足";
                if (target.HasValue && Location != target.Value.Location) Location = target.Value.Location;
            }
            else
            {
                followPlacementAvailable = false;
                connection = settings.Follow ? "未发现宠物 · 暂时隐藏组件" : settings.Position == "sidebarBottom" ? sidebar.Status : "独立浮窗 · 可拖动，右键设置";
            }
            ApplyVisibility();
            if ((now-lastSidebar).TotalSeconds >= 2) {
                lastSidebar = now;
                bool active = settings.Position == "sidebarBottom" && !hidden;
                sidebar.Configure(active, active ? SidebarClient.RenderPayload(snapshot,error,settings.Mode,settings.Theme,settings.Zoom) : null);
            }
            if ((now - lastPaint).TotalSeconds >= 1 || lastConnection != connection || Native.WindowDpi(Handle) != renderedDpi) { PaintSurface(); UpdateDetails(); }
        }
        void PaintSurface()
        {
            if (closing || suspended || !IsHandleCreated) return;
            uint dpi = Native.WindowDpi(Handle);
            renderedDpi = dpi;
            if (dpi > 0) scale = Math.Max(1, dpi / 96f) * settings.Zoom / 100f;
            using (Bitmap image = Art.Widget(snapshot, error, loading, settings.Mode, colors, connection, scale, DateTime.UtcNow)) Surface(image);
            lastPaint = DateTime.UtcNow; lastConnection = connection;
            int? five = Fresh && snapshot.FiveHour != null ? snapshot.FiveHour.Remaining(Time.Unix(DateTime.UtcNow)) : null;
            int? week = Fresh && snapshot.Weekly != null ? snapshot.Weekly.Remaining(Time.Unix(DateTime.UtcNow)) : null;
            if (tray != null) tray.Text = "PetsPet · 5小时 " + (five.HasValue ? five + "%" : "未知") + " · 本周 " + (week.HasValue ? week + "%" : "未知");
        }
        void UpdateDetails() { if (details != null && !details.IsDisposed) details.UpdateData(); }
        void DragStart(object sender, MouseEventArgs args)
        {
            if (args.Button != MouseButtons.Left) return;
            dragging = true; moved = false; dragOrigin = Cursor.Position; formOrigin = Location; Capture = true;
        }
        void DragMove(object sender, MouseEventArgs args)
        {
            if (!dragging) return;
            Point delta = new Point(Cursor.Position.X - dragOrigin.X, Cursor.Position.Y - dragOrigin.Y);
            if (!moved && Math.Abs(delta.X) + Math.Abs(delta.Y) < 6) return;
            moved = true; settings.Follow = false; settings.Position = "floating";
            Rectangle desired = new Rectangle(formOrigin.X + delta.X, formOrigin.Y + delta.Y, Width, Height);
            Location = Placement.Clamp(desired, Screen.FromPoint(Cursor.Position).WorkingArea).Location;
        }
        void DragEnd(object sender, MouseEventArgs args)
        {
            if (args.Button != MouseButtons.Left) return;
            Capture = false; dragging = false;
            if (moved) { settings.X = Left; settings.Y = Top; SaveSettings(); PaintSurface(); }
        }
        public void ShowWidget(bool reset)
        {
            hidden = false; petCollapsed = false; showItem.Text = "隐藏组件";
            if (reset)
            {
                Rectangle work = Screen.FromPoint(Cursor.Position).WorkingArea;
                Location = Placement.Clamp(new Rectangle(work.Right - Width - 28, work.Bottom - Height - 24, Width, Height), work).Location;
            }
            ApplyVisibility(); PaintSurface(); lastSidebar = DateTime.MinValue;
        }
        public void ShowDetails()
        {
            if (closing) return;
            if (details == null || details.IsDisposed) details = new DetailForm(this);
            details.ApplyTheme(); details.UpdateData();
            details.Show(); details.Activate();
        }
        public void ShowSettings(Control anchor) { menu.Show(anchor, new Point(0, anchor.Height)); }
        public string SavePicture()
        {
            try
            {
                string directory = Path.Combine(Settings.Root, "验收截图"); Directory.CreateDirectory(directory);
                string path = Path.Combine(directory, "实际运行_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".png");
                bool vertical = settings.Position == "sidebarBottom";
                float pictureScale = vertical ? 2f * settings.Zoom / 100f : scale;
                using (Bitmap image = Art.Widget(snapshot, error, loading, settings.Mode, colors, connection, pictureScale, DateTime.UtcNow, vertical)) image.Save(path, ImageFormat.Png);
                if (details != null && !details.IsDisposed) details.Notice("已保存组件图片到项目内的“验收截图”文件夹。");
                return path;
            }
            catch { if (details != null && !details.IsDisposed) details.Notice("截图保存失败，请检查项目文件夹是否可写。"); return null; }
        }
        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            closing = true; if (sidebarCancel != null) sidebarCancel.Cancel(); tick.Stop(); tracker.Dispose(); petMouse.Dispose(); sidebar.Dispose(); service.Dispose();
            SystemEvents.PowerModeChanged -= PowerChanged; SystemEvents.DisplaySettingsChanged -= DisplaysChanged;
            tray.Visible = false; tray.Dispose(); trayIcon.Dispose(); appIcon.Dispose();
            if (details != null && !details.IsDisposed) details.Close();
            showEvent.Dispose(); exitEvent.Dispose(); menu.Dispose(); tick.Dispose();
            base.OnFormClosing(e);
        }
    }

    sealed class DetailForm : Form
    {
        readonly Companion owner;
        readonly Label heading, subtitle, fiveNumber, weekNumber, fiveReset, weekReset, status, note;
        readonly Panel fiveCard, weekCard;
        readonly Button refresh, locate, picture, settingsButton;
        readonly ComboBox theme;
        readonly TrackBar sizeSlider;
        readonly Label sizePercent;
        readonly Button resetSize;
        readonly TableLayoutPanel layout;
        bool applying;
        public DetailForm(Companion companion)
        {
            owner = companion;
            Text = "PetsPet · 额度详情"; Icon = companion.Icon;
            Font = new Font("Microsoft YaHei UI", 9);
            AutoScaleMode = AutoScaleMode.None;
            ClientSize = new Size(470, 506); MinimumSize = new Size(450, 522);
            StartPosition = FormStartPosition.CenterScreen; FormBorderStyle = FormBorderStyle.FixedSingle; MaximizeBox = false;
            layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24, 20, 24, 18), ColumnCount = 1, RowCount = 8 };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            foreach (int height in new[] { 38, 30, 142, 72, 34, 52, 48, 40 }) layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
            Controls.Add(layout);
            heading = Label("额度在这里，安心写代码。", 16, true); layout.Controls.Add(heading, 0, 0);
            subtitle = Label("PET'S PET   /   WINDOWS 预览版", 8, false); layout.Controls.Add(subtitle, 0, 1);
            TableLayoutPanel cards = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0, 6, 0, 8) };
            cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50)); cards.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
            fiveCard = Card("5 小时剩余额度", Palette.Green, out fiveNumber, out fiveReset);
            weekCard = Card("本周剩余额度", Palette.Blue, out weekNumber, out weekReset);
            fiveCard.Margin = new Padding(0, 0, 6, 0); weekCard.Margin = new Padding(6, 0, 0, 0);
            cards.Controls.Add(fiveCard, 0, 0); cards.Controls.Add(weekCard, 1, 0); layout.Controls.Add(cards, 0, 2);
            status = Label("正在读取额度…", 9, false); status.Padding = new Padding(0, 7, 0, 0); layout.Controls.Add(status, 0, 3);
            FlowLayoutPanel preferences = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) };
            Label themeLabel = Label("外观", 9, false); themeLabel.AutoSize = true; themeLabel.Margin = new Padding(0, 5, 10, 0);
            theme = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 126, AccessibleName = "选择浮窗外观" };
            theme.Items.AddRange(new object[] { "跟随系统", "浅色", "深色" });
            theme.SelectedIndexChanged += delegate { if (!applying) owner.SetTheme(new[] { "system", "light", "dark" }[theme.SelectedIndex]); };
            preferences.Controls.Add(themeLabel); preferences.Controls.Add(theme);
            settingsButton = Button("位置 / 内容…", delegate(object sender, EventArgs e) { owner.ShowSettings((Control)sender); });
            settingsButton.Margin = new Padding(12, 0, 0, 0); preferences.Controls.Add(settingsButton);
            layout.Controls.Add(preferences, 0, 4);
            FlowLayoutPanel sizing = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0, 7, 0, 0) };
            Label sizeLabel = Label("大小", 9, false); sizeLabel.AutoSize = true; sizeLabel.Margin = new Padding(0, 6, 10, 0);
            sizeSlider = new TrackBar { Minimum = 50, Maximum = 200, SmallChange = 5, LargeChange = 25, TickStyle = TickStyle.None, AutoSize = false, Width = 214, Height = 30, Value = owner.Options.Zoom, AccessibleName = "浮窗大小百分比" };
            sizePercent = Label(owner.Options.Zoom + "%", 9, false); sizePercent.Dock = DockStyle.None; sizePercent.Size = new Size(48, 28); sizePercent.TextAlign = ContentAlignment.MiddleCenter;
            resetSize = Button("默认", delegate { owner.SetZoom(100); }); resetSize.Size = new Size(64, 28); resetSize.AccessibleName = "恢复默认浮窗大小";
            sizeSlider.ValueChanged += delegate { if (!applying) owner.SetZoom(sizeSlider.Value); };
            sizing.Controls.AddRange(new Control[] { sizeLabel, sizeSlider, sizePercent, resetSize }); layout.Controls.Add(sizing, 0, 5);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0, 6, 0, 0) };
            refresh = Button("立即刷新", delegate { owner.RefreshQuota(); });
            locate = Button("显示浮窗", delegate { if (owner.Options.Position == "sidebarBottom") owner.EnableSidebar(); else owner.ShowWidget(true); });
            picture = Button("保存截图", delegate { SaveDetailPicture(); owner.SavePicture(); });
            actions.Controls.AddRange(new Control[] { refresh, locate, picture }); layout.Controls.Add(actions, 0, 6);
            note = Label("大小可调 50%～200%，实时保存。\n穿透关闭时可右键双环；开启后请通过托盘设置。", 8, false); layout.Controls.Add(note, 0, 7);
            float dpiScale = Math.Max(1, Native.SystemDpi() / 96f);
            if (dpiScale != 1) Scale(new SizeF(dpiScale, dpiScale));
            HandleCreated += delegate { Native.DarkTitle(Handle, owner.Colors.Dark); };
            ApplyTheme(); UpdateData();
        }
        static Label Label(string text, float size, bool bold)
        {
            return new Label { Text = text, Dock = DockStyle.Fill, AutoSize = false, Font = new Font("Microsoft YaHei UI", size, bold ? FontStyle.Bold : FontStyle.Regular), Margin = new Padding(0), TextAlign = ContentAlignment.MiddleLeft };
        }
        static Button Button(string text, EventHandler click)
        {
            Button button = new Button { Text = text, Size = new Size(122, 33), Margin = new Padding(0, 0, 10, 0), FlatStyle = FlatStyle.Flat, Cursor = Cursors.Hand };
            button.FlatAppearance.BorderSize = 1; button.Click += click; return button;
        }
        static Panel Card(string name, Color accent, out Label number, out Label reset)
        {
            Panel panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 11, 12, 10) };
            TableLayoutPanel content = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = new Padding(0) };
            content.RowStyles.Add(new RowStyle(SizeType.Absolute, 24)); content.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); content.RowStyles.Add(new RowStyle(SizeType.Absolute, 24));
            Label title = Label(name, 9, false); title.Tag = "accent"; title.ForeColor = accent;
            number = Label("--", 27, true); reset = Label("等待官方数据", 8, false); reset.Tag = "muted";
            content.Controls.Add(title, 0, 0); content.Controls.Add(number, 0, 1); content.Controls.Add(reset, 0, 2); panel.Controls.Add(content);
            return panel;
        }
        public void ApplyTheme()
        {
            Palette colors = owner.Colors; BackColor = colors.Background; ForeColor = colors.Text;
            if (IsHandleCreated) Native.DarkTitle(Handle, colors.Dark);
            ApplyColors(this, colors);
            fiveCard.BackColor = weekCard.BackColor = colors.Surface;
            foreach (Button button in new[] { refresh, locate, picture, resetSize, settingsButton })
            { button.BackColor = colors.Surface; button.ForeColor = colors.Text; button.FlatAppearance.BorderColor = colors.Border; }
            subtitle.ForeColor = note.ForeColor = colors.Muted;
            theme.BackColor = colors.Surface; theme.ForeColor = colors.Text;
            sizeSlider.BackColor = colors.Background;
            applying = true; theme.SelectedIndex = Array.IndexOf(new[] { "system", "light", "dark" }, owner.Options.Theme); applying = false;
        }
        static void ApplyColors(Control control, Palette colors)
        {
            if ((string)control.Tag == "muted") control.ForeColor = colors.Muted;
            else if ((string)control.Tag != "accent") control.ForeColor = colors.Text;
            foreach (Control child in control.Controls) ApplyColors(child, colors);
        }
        public void UpdateData()
        {
            applying = true; sizeSlider.Value = owner.Options.Zoom; sizePercent.Text = owner.Options.Zoom + "%"; applying = false;
            QuotaSnapshot value = owner.Snapshot; double now = Time.Unix(DateTime.UtcNow);
            bool fresh = owner.Fresh;
            QuotaWindow five = value == null ? null : value.FiveHour, week = value == null ? null : value.Weekly;
            int? f = fresh && five != null ? five.Remaining(now) : null, w = fresh && week != null ? week.Remaining(now) : null;
            fiveNumber.Text = f.HasValue ? f + "%" : "--"; weekNumber.Text = w.HasValue ? w + "%" : "--";
            fiveReset.Text = fresh && five != null ? Time.Duration(five.Seconds(now)) + "后重置" : "暂不可用";
            weekReset.Text = fresh && week != null ? Time.Duration(week.Seconds(now)) + "后重置" : "暂不可用";
            string updated = value == null ? "尚未更新" : "最近更新 " + value.FetchedUtc.ToLocalTime().ToString("HH:mm:ss");
            status.Text = (owner.Loading ? "正在向官方服务刷新…" : owner.Error ?? (fresh ? "已连接官方额度服务 · 每 60 秒自动更新" : "数据已过期，等待重新读取")) + "\n" + updated + "\n" + owner.Connection;
            status.ForeColor = owner.Error == null ? owner.Colors.Muted : (owner.Colors.Dark ? Color.FromArgb(255, 185, 138) : Color.FromArgb(154, 80, 36));
            refresh.Enabled = !owner.Loading; refresh.Text = owner.Loading ? "更新中…" : "立即刷新";
            locate.Text = owner.Options.Position == "sidebarBottom" ? "连接侧栏" : "显示浮窗";
        }
        public void Notice(string text) { status.Text = text; }
        public void FocusSize() { sizeSlider.Focus(); }
        void SaveDetailPicture()
        {
            try
            {
                string directory = Path.Combine(Settings.Root, "验收截图"); Directory.CreateDirectory(directory);
                using (Bitmap image = new Bitmap(layout.Width, layout.Height))
                { layout.DrawToBitmap(image, new Rectangle(Point.Empty, layout.Size)); image.Save(Path.Combine(directory, "实际详情_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".png"), ImageFormat.Png); }
            }
            catch { Notice("详情截图暂时无法保存。"); }
        }
    }

    static class Native
    {
        public delegate bool EnumCallback(IntPtr window, IntPtr parameter);
        [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct Size { public int Width, Height; }
        [StructLayout(LayoutKind.Sequential, Pack = 1)] public struct Blend { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumCallback callback, IntPtr parameter);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
        [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
        [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
        [DllImport("user32.dll")] static extern uint GetDpiForSystem();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr value);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool UpdateLayeredWindow(IntPtr window, IntPtr screen, ref Point destination, ref Size size, IntPtr source, ref Point sourcePoint, int colorKey, ref Blend blend, int flags);
        public static uint SystemDpi() { try { return GetDpiForSystem(); } catch { return 96; } }
        public static void DarkTitle(IntPtr window, bool dark)
        { try { int value = dark ? 1 : 0; DwmSetWindowAttribute(window, 20, ref value, sizeof(int)); } catch { } }
        public static uint WindowDpi(IntPtr window) { try { return GetDpiForWindow(window); } catch { return SystemDpi(); } }
        public static Rectangle WindowBounds(IntPtr window)
        { Rect r; return GetWindowRect(window, out r) ? Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom) : Rectangle.Empty; }
        public static List<IntPtr> CodexWindows()
        {
            HashSet<uint> processes = new HashSet<uint>();
            foreach (Process process in Process.GetProcessesByName("ChatGPT"))
            {
                using (process)
                {
                    try
                    {
                        string path = process.MainModule.FileName;
                        if (path.IndexOf("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) >= 0 || path.IndexOf(@"\OpenAI\Codex\", StringComparison.OrdinalIgnoreCase) >= 0) processes.Add((uint)process.Id);
                    }
                    catch { }
                }
            }
            List<IntPtr> windows = new List<IntPtr>();
            EnumWindows(delegate(IntPtr window, IntPtr parameter)
            {
                uint process; GetWindowThreadProcessId(window, out process);
                if (processes.Contains(process) && IsWindowVisible(window) && !IsIconic(window))
                { Rectangle r = WindowBounds(window); if (r.Width > 0 && r.Height > 0) windows.Add(window); }
                return true;
            }, IntPtr.Zero);
            return windows;
        }
    }

    static class Checks
    {
        static int count;
        static void Check(bool value, string label) { count++; if (!value) throw new Exception(label); }
        public static object Run()
        {
            double now = Time.Unix(DateTime.UtcNow);
            Check(new QuotaWindow { Used = 0 }.Remaining(now) == 100, "real zero use");
            Check(new QuotaWindow { Used = 100 }.Remaining(now) == 0, "real exhausted quota");
            Check(new QuotaWindow().Remaining(now) == null, "missing is unknown");
            Check(new QuotaWindow { Used = 2, Reset = now - 1 }.Remaining(now) == null, "expired is unknown");
            Check(new QuotaWindow { Used = -20 }.Remaining(now) == 100, "negative use clamped");
            Check(new QuotaWindow { Used = 150 }.Remaining(now) == 0, "over limit clamped");
            Check(new QuotaWindow { Minutes = 300, Reset = now + 18001 }.Seconds(now) == null, "inconsistent reset");
            Check(new QuotaWindow { Minutes = 300, Reset = now + 600 }.Seconds(now) == 600, "valid countdown");
            Check(new QuotaWindow { Minutes = 300, Reset = now }.Seconds(now) == null, "zero countdown");
            Dictionary<string, object> quota = Json.Read("{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":7,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":18,\"windowDurationMins\":10080}}}}");
            QuotaSnapshot parsed = QuotaSnapshot.Parse(quota, DateTime.UtcNow);
            Check(parsed.FiveHour.Remaining(now) == 93 && parsed.Weekly.Remaining(now) == 82, "correct quota bucket");
            QuotaSnapshot legacy = QuotaSnapshot.Parse(Json.Read("{\"rateLimits\":{\"primary\":{\"usedPercent\":0,\"windowDurationMins\":10080},\"secondary\":{\"usedPercent\":100,\"windowDurationMins\":300}}}"), DateTime.UtcNow);
            Check(legacy.Weekly.Remaining(now) == 100 && legacy.FiveHour.Remaining(now) == 0, "legacy intervals can be reversed");
            Check(Json.Number(Json.Read("{\"usedPercent\":\"0\"}"), "usedPercent") == null, "string zero is not valid usage");
            Check(Json.Number(Json.Read("{\"usedPercent\":null}"), "usedPercent") == null, "null is not valid usage");
            bool rejected = false;
            try { QuotaSnapshot.Parse(Json.Read("{\"rateLimitsByLimitId\":{\"other\":{}},\"rateLimits\":{\"primary\":{\"windowDurationMins\":300}}}"), DateTime.UtcNow); } catch (QueryException) { rejected = true; }
            Check(rejected, "never use unrelated quota bucket");
            parsed.FetchedUtc = DateTime.UtcNow.AddSeconds(-151); Check(!parsed.Fresh(DateTime.UtcNow), "stale data");
            parsed.FetchedUtc = DateTime.UtcNow.AddMinutes(5); Check(!parsed.Fresh(DateTime.UtcNow), "clock moved backwards");
            Check(PetTracker.Identity("avatar-mascot-button", ""), "stable pet identifier");
            Check(PetTracker.Identity("", "Mochi pet"), "English pet label");
            Check(PetTracker.Identity("", "Mochi 虚拟宠物"), "Chinese pet label");
            Check(!PetTracker.Identity("", "pet settings"), "settings button is not pet");
            Check(!PetTracker.Identity("", "ChatGPT"), "main window is not pet");
            Rectangle work = new Rectangle(0, 0, 1280, 760), pet = new Rectangle(640, 580, 80, 80);
            Rectangle? placement = Placement.Follow(pet, pet, new Size(Art.Width, Art.Height), work);
            Check(placement.HasValue && work.Contains(placement.Value) && !pet.IntersectsWith(placement.Value), "placement avoids pet");
            Rectangle upperPet = new Rectangle(0, 10, 80, 80);
            Rectangle? lower = Placement.Follow(upperPet, upperPet, new Size(Art.Width, Art.Height), work);
            Check(lower.HasValue && lower.Value.Top >= upperPet.Bottom, "top edge placement");
            Rectangle negativeMonitor = new Rectangle(-1920, 0, 1920, 1080);
            Rectangle clamped = Placement.Clamp(new Rectangle(-3000, 1100, Art.Width, Art.Height), negativeMonitor);
            Check(negativeMonitor.Contains(clamped), "negative coordinate monitor");
            Check(!Placement.Follow(pet, pet, new Size(Art.Width, Art.Height), new Rectangle(0, 0, 100, 40)).HasValue, "small screen");
            Check(!Companion.FollowVisible(true, false, false) && Companion.FollowVisible(true, true, false), "follow hides without safe placement and recovers when available");
            Check(Time.Duration(60) == "1分钟", "countdown minute");
            Check(Time.Duration(86400) == "1天0小时", "countdown day");
            Check(Time.Duration(null) == "等待更新", "unknown countdown");
            Check(Settings.ClampZoom(20) == 50, "minimum custom size");
            Check(Settings.ClampZoom(300) == 200, "maximum custom size");
            Check(Settings.ClampZoom(75) == 75, "custom size preserved");
            QuotaSnapshot weeklyOnly = new QuotaSnapshot { Weekly = new QuotaWindow { Minutes = 10080 } };
            Check(Settings.ResolveMode("automatic", weeklyOnly) == "countdown", "automatic weekly-only countdown");
            Check(Settings.ResolveMode("automatic", legacy) == "quota", "automatic dual-window quota");
            Check(Settings.ResolveMode("automatic", null) == "quota", "automatic no data");
            Check(Settings.ResolveMode("quota", weeklyOnly) == "quota", "manual mode takes priority");
            Check(QuotaService.AccountPlan(Json.Read("{\"account\":{\"type\":\"chatgpt\",\"planType\":\"pro\"}}")) == "pro", "official account plan fallback");
            Check(QuotaService.AccountPlan(Json.Read("{\"account\":null}")) == null, "missing account is not PRO");
            PetGesture gesture = new PetGesture(); IntPtr petWindow = new IntPtr(42);
            gesture.Down(new Point(100,100),petWindow,true,0);
            Check(gesture.Up(new Point(102,101),petWindow,true,100), "exposed pet click toggles");
            Check(!gesture.Up(new Point(102,101),petWindow,true,200), "release without press ignored");
            gesture.Down(new Point(100,100),petWindow,true,0); gesture.Move(new Point(120,100));
            Check(!gesture.Up(new Point(100,100),petWindow,true,200), "drag returning to start is not click");
            gesture.Down(new Point(100,100),petWindow,false,0);
            Check(!gesture.Up(new Point(100,100),petWindow,true,100), "occluded pet is not clicked");
            gesture.Down(new Point(100,100),petWindow,true,0);
            Check(!gesture.Up(new Point(100,100),new IntPtr(43),true,100), "replaced pet ignored");
            gesture.Down(new Point(100,100),petWindow,true,0); gesture.Reset();
            Check(!gesture.Up(new Point(100,100),petWindow,true,100), "sleep cancels pending click");
            Check(SidebarClient.AllowedSocket("ws://127.0.0.1:39222/devtools/page/abc"), "local sidebar endpoint allowed");
            Check(!SidebarClient.AllowedSocket("ws://example.com:39222/devtools/page/abc"), "remote sidebar endpoint rejected");
            Check(!SidebarClient.AllowedSocket("ws://127.0.0.1:9222/devtools/page/abc"), "other debug port rejected");
            Check(!SidebarClient.AllowedSocket("ws://user@127.0.0.1:39222/devtools/page/abc"), "endpoint credentials rejected");
            Check(SidebarClient.MainPage("app://-/index.html"), "main Codex page accepted");
            Check(!SidebarClient.MainPage("app://-/index.html?window=overlay"), "overlay excluded from sidebar");
            Check(!SidebarClient.MainPage("https://example.com/index.html"), "web pages excluded from sidebar");
            string installation = @"C:\Program Files\WindowsApps\OpenAI.Codex_1.0_x64__test\app\ChatGPT.exe";
            ProcessStartInfo launchInfo = SidebarLauncher.StartInfo(installation);
            Check(launchInfo.FileName == installation && !launchInfo.UseShellExecute && launchInfo.Arguments.Contains("--remote-debugging-port=39222"), "direct launch keeps debug arguments");
            bool unsafePathRejected = false;
            try { SidebarLauncher.StartInfo(@"D:\Temp\ChatGPT.exe"); } catch (ArgumentException) { unsafePathRejected = true; }
            Check(unsafePathRejected, "unverified application path rejected");
            bool launched = false;
            Action<string> ignoreProgress = delegate { };
            string outcome = SidebarLauncher.OpenSteps(() => true, () => launched = true, () => true, ignoreProgress, CancellationToken.None, 0);
            Check(outcome == null && !launched, "existing connection does not reopen app");
            outcome = SidebarLauncher.OpenSteps(() => true, () => launched = true, () => false, ignoreProgress, CancellationToken.None, 0);
            Check(outcome != null && !launched, "running app prompts manual exit without launching");
            outcome = SidebarLauncher.OpenSteps(() => false, () => launched = true, () => launched, ignoreProgress, CancellationToken.None, 0);
            Check(outcome == null && launched, "manually exited app opens with connection");
            launched = false;
            outcome = SidebarLauncher.OpenSteps(() => false, () => launched = true, () => false, ignoreProgress, CancellationToken.None, 0);
            Check(outcome != null && launched, "starting process alone is not connection success");
            using (CancellationTokenSource cancelled = new CancellationTokenSource()) {
                launched = false; bool stopped = false;
                try { SidebarLauncher.OpenSteps(() => false, () => launched = true, delegate { cancelled.Cancel(); return false; }, ignoreProgress, cancelled.Token, 0); }
                catch (OperationCanceledException) { stopped = true; }
                Check(stopped && !launched, "cancel during probe never opens an app");
            }
            Dictionary<string,object> payload = Json.Read(SidebarClient.RenderPayload(weeklyOnly,null,"automatic","system",73));
            Check(Math.Abs(Json.Number(payload,"width").Value-46.72) < .01 && Math.Abs(Json.Number(payload,"height").Value-93.44) < .01, "sidebar preserves custom size");
            using (MemoryStream png = new MemoryStream(Convert.FromBase64String(Json.Text(payload,"dark").Substring(22))))
            using (Bitmap image = new Bitmap(png)) Check(image.Width == 93 && image.Height == 187, "sidebar retina PNG dimensions");
            using (Icon original = OriginalAssets.ApplicationIcon()) Check(original.Width == 32, "embedded original application icon");
            using (Icon original = OriginalAssets.TrayIcon()) Check(original.Width == 32, "embedded original tray icon");
            using (LayerForm testWindow = new LayerForm()) {
                IntPtr handle = testWindow.Handle;
                testWindow.MouseThrough(true);
                Check((Native.GetWindowLongPtr(handle,-20).ToInt64() & 0x20) != 0, "native mouse-through enabled");
                testWindow.MouseThrough(false);
                Check((Native.GetWindowLongPtr(handle,-20).ToInt64() & 0x20) == 0, "native mouse interaction restored");
                Check((Native.GetWindowLongPtr(handle,-20).ToInt64() & 0x08000000) != 0, "widget does not take keyboard focus");
            }
            using (Bitmap compact = Art.Widget(null, null, true, "quota", Palette.For("dark"), "", .5f, DateTime.UtcNow))
                Check(compact.Width == 64 && compact.Height == 32, "50 percent drawing dimensions");
            using (Bitmap normal = Art.Widget(null, null, true, "quota", Palette.For("dark"), "", 1f, DateTime.UtcNow))
            {
                Check(normal.Width == 128 && normal.Height == 64, "upstream body proportions");
                Check(normal.GetPixel(0, 0).A == 0, "outside shape is transparent");
                int alpha = normal.GetPixel(64, 32).A;
                Check(alpha > 0 && alpha < 255, "upstream translucent background");
            }
            using (Bitmap large = Art.Widget(null, null, true, "quota", Palette.For("light"), "", 2f, DateTime.UtcNow))
                Check(large.Width == 256 && large.Height == 128, "200 percent drawing dimensions");
            return new { passed = true, assertions = count, utc = DateTime.UtcNow.ToString("o") };
        }
        public static object Smoke(Settings settings)
        {
            using (QuotaService service = new QuotaService(settings.CodexHome))
            {
                QuotaSnapshot value = service.Fetch(); double now = Time.Unix(DateTime.UtcNow);
                return new { passed = true, source = "official account/rateLimits/read", fiveHourRemaining = value.FiveHour == null ? null : value.FiveHour.Remaining(now), weeklyRemaining = value.Weekly == null ? null : value.Weekly.Remaining(now), fetchedUtc = value.FetchedUtc.ToString("o") };
            }
        }
        public static object SidebarTransport()
        {
            using (SidebarClient client = new SidebarClient())
            {
                client.Configure(true, SidebarClient.RenderPayload(null,null,"automatic","dark",73));
                Stopwatch timeout = Stopwatch.StartNew();
                while (timeout.ElapsedMilliseconds < 8000 && client.Status != "头像上方竖向双环 · 已连接") Thread.Sleep(100);
                Check(client.Status == "头像上方竖向双环 · 已连接", "CDP discovery, websocket and evaluation");
                client.Configure(false,null); timeout.Restart();
                while (timeout.ElapsedMilliseconds < 5000 && client.Status != "侧栏已断开") Thread.Sleep(100);
                Check(client.Status == "侧栏已断开", "CDP cleanup evaluation");
                return new { passed = true, fixture = true, assertions = count };
            }
        }
        public static object Probe()
        {
            AutomationElement target; PetAnchor anchor = PetTracker.Scan(out target);
            return new { found = anchor.Found, status = anchor.Status, pet = anchor.Found ? (object)new { x = anchor.Pet.X, y = anchor.Pet.Y, width = anchor.Pet.Width, height = anchor.Pet.Height } : null };
        }
        public static object Render(string directory)
        {
            Directory.CreateDirectory(directory);
            DateTime now = DateTime.UtcNow; double epoch = Time.Unix(now);
            QuotaSnapshot sample = new QuotaSnapshot { FetchedUtc = now, FiveHour = new QuotaWindow { Used = 34, Minutes = 300, Reset = epoch + 12540 }, Weekly = new QuotaWindow { Used = 12, Minutes = 10080, Reset = epoch + 259200 } };
            int files = 0;
            foreach (string theme in new[] { "light", "dark" })
            foreach (float scale in new[] { 1f, 1.5f, 2f })
            foreach (string mode in new[] { "quota", "countdown", "error", "missing", "expired", "full", "zero", "minutes", "pro", "weeklyOnly" })
            {
                QuotaSnapshot value = mode == "missing" ? null : mode == "expired" ? new QuotaSnapshot { FetchedUtc = now.AddMinutes(-5), FiveHour = sample.FiveHour, Weekly = sample.Weekly } : sample;
                if (mode == "full" || mode == "zero" || mode == "minutes") value = new QuotaSnapshot { FetchedUtc = now, FiveHour = new QuotaWindow { Used = mode == "zero" ? 100 : 0, Minutes = 300, Reset = epoch + 600 }, Weekly = new QuotaWindow { Used = mode == "zero" ? 100 : 0, Minutes = 10080, Reset = epoch + 259200 } };
                if (mode == "pro") value = new QuotaSnapshot { FetchedUtc = now, Plan = "pro", FiveHour = sample.FiveHour, Weekly = sample.Weekly };
                if (mode == "weeklyOnly") value = new QuotaSnapshot { FetchedUtc = now, Weekly = sample.Weekly };
                using (Bitmap image = Art.Widget(value, mode == "error" ? "读取失败" : null, false, mode == "weeklyOnly" ? "automatic" : mode == "countdown" || mode == "minutes" ? "countdown" : "quota", Palette.For(theme), "视觉样本 · 非账号数据", scale, now))
                    image.Save(Path.Combine(directory, String.Format("样本_{0}_{1}_{2}.png", theme, mode, scale.ToString("0.0", CultureInfo.InvariantCulture))), ImageFormat.Png);
                files++;
            }
            foreach (string theme in new[] { "light", "dark" })
            foreach (float scale in new[] { 1f, 1.5f, 2f }) {
                using (Bitmap image = Art.Widget(sample,null,false,"quota",Palette.For(theme),"",scale,now,true))
                    image.Save(Path.Combine(directory,String.Format("样本_{0}_sidebar_{1}.png",theme,scale.ToString("0.0",CultureInfo.InvariantCulture))),ImageFormat.Png);
                files++;
            }
            return new { passed = true, renderedImages = files };
        }
    }

    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Settings settings = Settings.Load();
            string command = args.Length > 0 ? args[0] : "";
            if (new[] { "--self-test", "--smoke-test", "--probe-pet", "--render-checks", "--sidebar-check", "--sidebar-status" }.Contains(command))
            {
                string output = args.Length > 1 ? Path.GetFullPath(args[1]) : Path.Combine(Settings.Data, command.Substring(2) + ".json");
                try
                {
                    object result = command == "--self-test" ? Checks.Run() : command == "--smoke-test" ? Checks.Smoke(settings) : command == "--probe-pet" ? Checks.Probe() : command == "--sidebar-check" ? Checks.SidebarTransport() : command == "--sidebar-status" ? SidebarLauncher.Diagnose(settings.CodexExecutable) : Checks.Render(Path.Combine(Settings.Root, "验收截图", "视觉样本"));
                    Directory.CreateDirectory(Path.GetDirectoryName(output)); File.WriteAllText(output, Json.Write(result), new UTF8Encoding(false)); return 0;
                }
                catch (Exception exception)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(output));
                    File.WriteAllText(output, Json.Write(new { passed = false, errorType = exception.GetType().Name, reason = exception is QueryException ? exception.Message : "检查未通过；请检查源码中的对应检查项。" }), new UTF8Encoding(false)); return 1;
                }
            }
            if (command == "--quit")
            {
                try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting("Local\\PetsPet.Windows.Exit")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                return 0;
            }
            bool first;
            using (Mutex mutex = new Mutex(true, "Local\\PetsPet.Windows.Singleton", out first))
            {
                if (!first)
                {
                    try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting("Local\\PetsPet.Windows.Show")) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                    return 0;
                }
                try
                {
                    Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
                    Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
                    using (Companion window = new Companion(settings, command == "--details")) Application.Run(window);
                    return 0;
                }
                catch
                {
                    MessageBox.Show("PetsPet 暂时无法启动。请确认项目文件夹可写，以及 Windows 的 .NET Framework 4.x 可用。", "PetsPet", MessageBoxButtons.OK, MessageBoxIcon.Information); return 1;
                }
                finally { mutex.ReleaseMutex(); }
            }
        }
    }
}
