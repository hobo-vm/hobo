// hobo ui's backend in a Windows guest (designs/hobo-ui-linux-windows.md). The VM process's
// UIDriver speaks to it in JSON lines over stdin and stdout for one command's life: it reads the
// tree through UI Automation and sends input with SendInput, as a person's mouse and keyboard.
// hobo-agent fetches it as the `ui` tool and starts it in the desktop session. Coordinates are
// the screen's pixels (the manifest makes it per-monitor DPI aware).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;

namespace Hobo
{
    class Failure : Exception
    {
        public Failure(string message) : base(message) { }
    }

    static class Program
    {
        static void Main()
        {
            var input = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1000 };
            var backend = new Backend();
            string line;
            while ((line = input.ReadLine()) != null)
            {
                object answer;
                try
                {
                    var request = json.DeserializeObject(line) as Dictionary<string, object>;
                    if (request == null) throw new Failure("not a JSON object");
                    answer = new Dictionary<string, object> { ["ok"] = backend.Handle(request) };
                }
                catch (Failure error)
                {
                    answer = new Dictionary<string, object> { ["error"] = error.Message };
                }
                catch (ElementNotAvailableException)
                {
                    answer = new Dictionary<string, object> { ["error"] = "the element is gone" };
                }
                catch (Exception error)
                {
                    answer = new Dictionary<string, object> { ["error"] = error.GetType().Name + ": " + error.Message };
                }
                output.WriteLine(json.Serialize(answer));
            }
        }
    }

    /// An app: its top-level windows, under an element of its own, which UI Automation hasn't.
    class AppNode
    {
        public int Pid;
    }

    class Backend
    {
        const int TreeLimit = 20000;
        const int TextLimit = 2000;

        readonly List<object> elements = new List<object>();
        readonly Dictionary<string, int> ids = new Dictionary<string, int>();
        readonly Input input = new Input();

        static readonly CacheRequest Properties = MakeCacheRequest();

        static CacheRequest MakeCacheRequest()
        {
            var request = new CacheRequest { TreeFilter = Automation.ControlViewCondition, AutomationElementMode = AutomationElementMode.Full };
            foreach (var property in new[] {
                AutomationElement.ControlTypeProperty, AutomationElement.NameProperty, AutomationElement.AutomationIdProperty,
                AutomationElement.HelpTextProperty, AutomationElement.BoundingRectangleProperty, AutomationElement.IsEnabledProperty,
                AutomationElement.HasKeyboardFocusProperty, AutomationElement.ProcessIdProperty, AutomationElement.ClassNameProperty,
                AutomationElement.IsValuePatternAvailableProperty, ValuePattern.ValueProperty,
                AutomationElement.IsTogglePatternAvailableProperty, TogglePattern.ToggleStateProperty,
                AutomationElement.IsSelectionItemPatternAvailableProperty, SelectionItemPattern.IsSelectedProperty,
            })
                request.Add(property);
            return request;
        }

        // MARK: Elements

        static string Key(AutomationElement element) => string.Join(".", element.GetRuntimeId());

        int Id(object element)
        {
            var key = element is AppNode app ? "app:" + app.Pid : Key((AutomationElement)element);
            if (!ids.TryGetValue(key, out var id))
            {
                id = elements.Count;
                elements.Add(element);
                ids[key] = id;
            }
            else
            {
                elements[id] = element;
            }
            return id;
        }

        object Get(Dictionary<string, object> request)
        {
            if (!(request.TryGetValue("id", out var value) && value is int id) || id < 0 || id >= elements.Count)
                throw new Failure("no element " + request.GetValueOrDefault("id") + " this session");
            return elements[id];
        }

        AutomationElement GetElement(Dictionary<string, object> request) =>
            Get(request) as AutomationElement ?? throw new Failure("that's an app, not an element");

        static List<double> Rect(Rect r) => r.IsEmpty ? null : new List<double> { r.X, r.Y, r.Width, r.Height };

        static T Cached<T>(AutomationElement element, AutomationProperty property, T fallback)
        {
            try
            {
                var value = element.GetCachedPropertyValue(property, true);
                return value is T typed ? typed : fallback;
            }
            catch (InvalidOperationException)
            {
                // Not cached: a live element, from FromPoint or a parent.
                var value = element.GetCurrentPropertyValue(property, true);
                return value is T typed ? typed : fallback;
            }
        }

        Dictionary<string, object> Node(object element, bool withChildren = false, int[] budget = null)
        {
            if (element is AppNode app) return AppTree(app, withChildren, budget ?? new[] { TreeLimit });
            var e = (AutomationElement)element;
            var type = Cached<ControlType>(e, AutomationElement.ControlTypeProperty, ControlType.Custom);
            var node = new Dictionary<string, object> { ["id"] = Id(e), ["role"] = type.ProgrammaticName.Replace("ControlType.", "") };
            var name = Cached(e, AutomationElement.NameProperty, "");
            if (name.Length > 0) node["title"] = name;
            var identifier = Cached(e, AutomationElement.AutomationIdProperty, "");
            if (identifier.Length > 0) node["identifier"] = identifier;
            var help = Cached(e, AutomationElement.HelpTextProperty, "");
            if (help.Length > 0) node["label"] = help;
            if (Cached(e, AutomationElement.IsValuePatternAvailableProperty, false))
            {
                var value = Cached(e, ValuePattern.ValueProperty, "");
                if (value.Length > 0 && value != name) node["value"] = value.Length > TextLimit ? value.Substring(0, TextLimit) : value;
            }
            var frame = Rect(Cached(e, AutomationElement.BoundingRectangleProperty, System.Windows.Rect.Empty));
            if (frame != null) node["frame"] = frame;
            if (!Cached(e, AutomationElement.IsEnabledProperty, true)) node["enabled"] = false;
            if (Cached(e, AutomationElement.HasKeyboardFocusProperty, false)) node["focused"] = true;
            if (Cached(e, AutomationElement.IsSelectionItemPatternAvailableProperty, false) && Cached(e, SelectionItemPattern.IsSelectedProperty, false))
                node["selected"] = true;
            if (Cached(e, AutomationElement.IsTogglePatternAvailableProperty, false))
                node["checked"] = Cached(e, TogglePattern.ToggleStateProperty, ToggleState.Off) == ToggleState.On;
            if (withChildren) node["children"] = Children(e, budget ?? new[] { TreeLimit });
            return node;
        }

        List<object> Children(AutomationElement element, int[] budget)
        {
            var found = new List<object>();
            AutomationElementCollection children;
            try { children = element.CachedChildren; }
            catch (InvalidOperationException)
            {
                // A live element: fetch its subtree with everything cached, once.
                try { children = element.GetUpdatedCache(SubtreeRequest()).CachedChildren; }
                catch (ElementNotAvailableException) { return found; }
            }
            if (children == null) return found;
            foreach (AutomationElement child in children)
            {
                if (budget[0]-- <= 0) break;
                found.Add(Node(child, true, budget));
            }
            return found;
        }

        static CacheRequest SubtreeRequest()
        {
            var request = Properties.Clone();
            request.TreeScope = TreeScope.Element | TreeScope.Descendants;
            return request;
        }

        static IEnumerable<AutomationElement> TopWindows(int pid)
        {
            var condition = new PropertyCondition(AutomationElement.ProcessIdProperty, pid);
            return AutomationElement.RootElement.FindAll(TreeScope.Children, condition).Cast<AutomationElement>();
        }

        Dictionary<string, object> AppTree(AppNode app, bool withChildren, int[] budget)
        {
            var node = new Dictionary<string, object> { ["id"] = Id(app), ["role"] = "Application", ["title"] = AppName(app.Pid) };
            if (withChildren)
            {
                var windows = new List<object>();
                foreach (var window in TopWindows(app.Pid))
                {
                    AutomationElement cached;
                    try { cached = window.GetUpdatedCache(SubtreeRequest()); }
                    catch (ElementNotAvailableException) { continue; }
                    windows.Add(Node(cached, true, budget));
                }
                node["children"] = windows;
            }
            return node;
        }

        // MARK: Apps

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern int GetApplicationUserModelId(IntPtr process, ref uint length, StringBuilder id);

        /// A packaged app's AUMID (Microsoft.WindowsNotepad_8wekyb3d8bbwe!App), else null.
        static string Aumid(Process process)
        {
            try
            {
                uint length = 256;
                var id = new StringBuilder((int)length);
                return GetApplicationUserModelId(process.Handle, ref length, id) == 0 ? id.ToString() : null;
            }
            catch (Exception) { return null; }
        }

        static string AppName(int pid)
        {
            try
            {
                var process = Process.GetProcessById(pid);
                try
                {
                    var description = process.MainModule?.FileVersionInfo.FileDescription;
                    if (!string.IsNullOrWhiteSpace(description)) return description;
                }
                catch (Exception) { }
                return process.ProcessName;
            }
            catch (Exception) { return "pid " + pid; }
        }

        static Dictionary<string, object> Identity(int pid)
        {
            string exe = null, aumid = null;
            try
            {
                var process = Process.GetProcessById(pid);
                exe = process.ProcessName;
                aumid = Aumid(process);
            }
            catch (Exception) { }
            var aliases = new List<object>();
            if (exe != null && aumid != null) aliases.Add(exe);
            return new Dictionary<string, object> { ["name"] = AppName(pid), ["id"] = aumid ?? exe, ["pid"] = pid, ["aliases"] = aliases };
        }

        object Apps()
        {
            var pids = new List<int>();
            foreach (AutomationElement window in AutomationElement.RootElement.FindAll(TreeScope.Children, Condition.TrueCondition))
            {
                int pid;
                try { pid = window.Current.ProcessId; }
                catch (ElementNotAvailableException) { continue; }
                if (pid != Process.GetCurrentProcess().Id && !pids.Contains(pid)) pids.Add(pid);
            }
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var focused);
            return new Dictionary<string, object>
            {
                ["apps"] = pids.Select(pid => (object)Identity(pid)).ToList(),
                ["focused"] = focused == 0 ? null : (object)(int)focused,
            };
        }

        // MARK: Windows

        static AutomationElement TopLevel(AutomationElement element)
        {
            var walker = TreeWalker.ControlViewWalker;
            var current = element;
            for (var i = 0; i < 200; i++)
            {
                var parent = walker.GetParent(current);
                if (parent == null || parent == AutomationElement.RootElement) return current;
                current = parent;
            }
            return current;
        }

        object Parent(AutomationElement element)
        {
            var parent = TreeWalker.ControlViewWalker.GetParent(element);
            if (parent == null) return null;
            if (parent == AutomationElement.RootElement) return Node(new AppNode { Pid = element.Current.ProcessId });
            return Node(parent);
        }

        void Raise(AutomationElement element)
        {
            var window = TopLevel(element);
            var handle = new IntPtr(window.Current.NativeWindowHandle);
            if (handle == IntPtr.Zero || Native.GetForegroundWindow() == handle) return;
            if (window.TryGetCurrentPattern(WindowPattern.Pattern, out var pattern)
                && ((WindowPattern)pattern).Current.WindowVisualState == WindowVisualState.Minimized)
                ((WindowPattern)pattern).SetWindowVisualState(WindowVisualState.Normal);
            // Windows lets a process take the foreground just after a key it sent: Alt, which does
            // nothing alone.
            input.Tap(Input.VK_MENU);
            Native.SetForegroundWindow(handle);
            var deadline = DateTime.Now.AddSeconds(2);
            while (Native.GetForegroundWindow() != handle && DateTime.Now < deadline) Thread.Sleep(50);
            Thread.Sleep(100);
        }

        object Windows(List<double> area)
        {
            var wanted = new Rect(area[0], area[1], area[2], area[3]);
            var found = new List<object>();
            foreach (var (handle, bounds, cloaked) in Native.TopWindows())
                if (bounds.IntersectsWith(wanted))
                    found.Add(new Dictionary<string, object> { ["id"] = handle.ToInt64(), ["bounds"] = Rect(bounds), ["alpha"] = cloaked ? 0.0 : 1.0 });
            return found;
        }

        /// A Win32 pop-up menu (class #32768) or a XAML flyout menu that is open where `point` isn't.
        object OpenMenu(double x, double y)
        {
            foreach (var (handle, bounds, cloaked) in Native.TopWindows())
            {
                if (cloaked || Native.ClassName(handle) != "#32768") continue;
                if (bounds.Contains(new System.Windows.Point(x, y))) return null;
                Native.GetWindowThreadProcessId(handle, out var pid);
                return "a menu of " + AppName((int)pid);
            }
            return null;
        }

        // MARK: Actions

        static void Press(AutomationElement element)
        {
            if (element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke)) ((InvokePattern)invoke).Invoke();
            else if (element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle)) ((TogglePattern)toggle).Toggle();
            else if (element.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var select)) ((SelectionItemPattern)select).Select();
            else if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expand)) ((ExpandCollapsePattern)expand).Expand();
            else throw new Failure("it has no Invoke, Toggle, SelectionItem or ExpandCollapse pattern to press");
        }

        static bool ScrollTo(AutomationElement element)
        {
            if (!element.TryGetCurrentPattern(ScrollItemPattern.Pattern, out var pattern)) return false;
            try { ((ScrollItemPattern)pattern).ScrollIntoView(); return true; }
            catch (InvalidOperationException) { return false; }
        }

        // MARK: Menus

        object MenuBar(AppNode app)
        {
            foreach (var window in TopWindows(app.Pid))
            {
                var bars = window.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuBar));
                // Win32 windows have the system menu's bar too, named System.
                foreach (AutomationElement bar in bars)
                    if (bar.Current.Name != "System") return Node(bar.GetUpdatedCache(Properties));
            }
            return null;
        }

        /// A menu bar's items, or what a menu item opens, expanding it first. A Win32 menu opens as
        /// a top-level menu window named after its item; a XAML flyout's items come under the item.
        object MenuItems(AutomationElement element)
        {
            var itemCondition = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuItem);
            if (element.Current.ControlType == ControlType.MenuBar)
                return element.FindAll(TreeScope.Children, itemCondition).Cast<AutomationElement>().Select(e => (object)Node(e.GetUpdatedCache(Properties))).ToList();
            if (element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var pattern))
            {
                var expand = (ExpandCollapsePattern)pattern;
                if (expand.Current.ExpandCollapseState == ExpandCollapseState.LeafNode) return new List<object>();
                if (expand.Current.ExpandCollapseState != ExpandCollapseState.Expanded) expand.Expand();
            }
            var name = element.Current.Name;
            var deadline = DateTime.Now.AddSeconds(2);
            while (DateTime.Now < deadline)
            {
                var under = element.FindAll(TreeScope.Descendants, itemCondition);
                if (under.Count > 0) return under.Cast<AutomationElement>().Select(e => (object)Node(e.GetUpdatedCache(Properties))).ToList();
                var menu = AutomationElement.RootElement.FindFirst(TreeScope.Descendants, new AndCondition(
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Menu),
                    new PropertyCondition(AutomationElement.NameProperty, name)));
                if (menu != null)
                    return menu.FindAll(TreeScope.Children, itemCondition).Cast<AutomationElement>().Select(e => (object)Node(e.GetUpdatedCache(Properties))).ToList();
                Thread.Sleep(50);
            }
            return new List<object>();
        }

        static object MenuItem(AutomationElement element)
        {
            var current = element.Current;
            var checkedState = element.TryGetCurrentPattern(TogglePattern.Pattern, out var toggle) && ((TogglePattern)toggle).Current.ToggleState == ToggleState.On;
            var submenu = element.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out var expand)
                && ((ExpandCollapsePattern)expand).Current.ExpandCollapseState != ExpandCollapseState.LeafNode;
            string shortcut = null;
            var accelerator = current.AcceleratorKey;
            if (!string.IsNullOrEmpty(accelerator))
                shortcut = string.Join("+", accelerator.Split('+').Select(part => part.Trim().ToLowerInvariant() switch { "win" => "cmd", "alt" => "alt", var other => other }));
            return new Dictionary<string, object>
            {
                ["title"] = current.Name, ["enabled"] = current.IsEnabled, ["checked"] = checkedState, ["shortcut"] = shortcut, ["submenu"] = submenu,
            };
        }

        // MARK: Requests

        static double Number(Dictionary<string, object> request, string key) => Convert.ToDouble(request[key]);

        static List<string> Mods(Dictionary<string, object> request) =>
            request.TryGetValue("mods", out var value) && value is object[] mods ? mods.Select(m => m.ToString()).ToList() : new List<string>();

        static List<double> Numbers(object value) => ((object[])value).Select(Convert.ToDouble).ToList();

        public object Handle(Dictionary<string, object> request)
        {
            var op = request.GetValueOrDefault("op") as string;
            switch (op)
            {
                case "hello":
                    var screen = Native.VirtualScreen();
                    return new Dictionary<string, object> { ["platform"] = "windows", ["scale"] = 1.0, ["screen"] = Rect(screen), ["access"] = null };
                case "apps": return Apps();
                case "tree": return Node(new AppNode { Pid = Convert.ToInt32(request["pid"]) }, true);
                case "children":
                    var parent = Get(request);
                    if (parent is AppNode app) return AppTree(app, true, new[] { TreeLimit })["children"];
                    return Children(((AutomationElement)parent).GetUpdatedCache(SubtreeRequest()), new[] { TreeLimit });
                case "node":
                    var element = Get(request);
                    if (element is AppNode) return Node(element);
                    try { return Node(((AutomationElement)element).GetUpdatedCache(Properties)); }
                    catch (ElementNotAvailableException) { return null; }
                case "parent":
                    if (Get(request) is AppNode) return null;
                    try { return Parent(GetElement(request)); }
                    catch (ElementNotAvailableException) { return null; }
                case "at":
                    var hit = AutomationElement.FromPoint(new System.Windows.Point(Number(request, "x"), Number(request, "y")));
                    return hit == null ? null : Node(hit.GetUpdatedCache(Properties));
                case "app_of":
                    var of = Get(request);
                    return Identity(of is AppNode a ? a.Pid : ((AutomationElement)of).Current.ProcessId);
                case "raise":
                    if (Get(request) is AutomationElement toRaise) Raise(toRaise);
                    return null;
                case "windows": return Windows(Numbers(request["area"]));
                case "open_menu": return OpenMenu(Number(request, "x"), Number(request, "y"));
                case "press": Press(GetElement(request)); return null;
                case "scroll_to": return ScrollTo(GetElement(request));
                case "menubar":
                    return Get(request) is AppNode barApp ? MenuBar(barApp) : null;
                case "menu_items": return MenuItems(GetElement(request));
                case "menu_item": return MenuItem(GetElement(request));
                case "click":
                    input.Click(Number(request, "x"), Number(request, "y"), request.GetValueOrDefault("right") as bool? ?? false,
                        Convert.ToInt32(request.GetValueOrDefault("count") ?? 1), Mods(request));
                    return null;
                case "drag":
                    var from = Numbers(request["from"]);
                    var to = Numbers(request["to"]);
                    input.Drag(from[0], from[1], to[0], to[1], Mods(request));
                    return null;
                case "scroll":
                    var notches = request.ContainsKey("lines") ? Convert.ToInt32(request["lines"]) : Math.Max(1, (int)Math.Round(Number(request, "distance") / 50));
                    input.Scroll(Number(request, "x"), Number(request, "y"), (string)request["direction"], notches);
                    return null;
                case "key":
                    input.Key((string)request["key"], Mods(request));
                    return null;
                case "type":
                    input.Type((string)request["text"]);
                    return null;
                default:
                    throw new Failure("unknown request " + op);
            }
        }
    }

    static class Extensions
    {
        public static object GetValueOrDefault(this Dictionary<string, object> dictionary, string key) =>
            dictionary.TryGetValue(key, out var value) ? value : null;
    }

    // MARK: Input

    /// SendInput: what the system takes as a person's mouse and keyboard.
    class Input
    {
        public const ushort VK_MENU = 0x12;
        const ushort VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_LWIN = 0x5B;

        static readonly Dictionary<string, ushort> Keys = MakeKeys();
        static readonly HashSet<ushort> Extended = new HashSet<ushort> { 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2E };

        static Dictionary<string, ushort> MakeKeys()
        {
            var keys = new Dictionary<string, ushort>();
            for (var c = 'a'; c <= 'z'; c++) keys[c.ToString()] = (ushort)char.ToUpperInvariant(c);
            for (var d = '0'; d <= '9'; d++) keys[d.ToString()] = d;
            var named = new Dictionary<string, ushort>
            {
                ["-"] = 0xBD, ["="] = 0xBB, ["["] = 0xDB, ["]"] = 0xDD, [";"] = 0xBA, ["'"] = 0xDE, ["`"] = 0xC0, ["\\"] = 0xDC,
                [","] = 0xBC, ["."] = 0xBE, ["/"] = 0xBF, ["return"] = 0x0D, ["tab"] = 0x09, ["space"] = 0x20, ["delete"] = 0x08,
                ["forwarddelete"] = 0x2E, ["escape"] = 0x1B, ["home"] = 0x24, ["end"] = 0x23, ["pageup"] = 0x21, ["pagedown"] = 0x22,
                ["left"] = 0x25, ["up"] = 0x26, ["right"] = 0x27, ["down"] = 0x28,
            };
            foreach (var pair in named) keys[pair.Key] = pair.Value;
            for (var f = 1; f <= 12; f++) keys["f" + f] = (ushort)(0x70 + f - 1);
            return keys;
        }

        static ushort Modifier(string name) => name switch
        {
            "command" => VK_LWIN, "control" => VK_CONTROL, "option" => VK_MENU, "shift" => VK_SHIFT, _ => (ushort)0,
        };

        static void Send(params Native.INPUT[] inputs) => Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Native.INPUT)));

        static Native.INPUT KeyInput(ushort vk, bool up, bool unicode = false, ushort scan = 0)
        {
            uint flags = (up ? Native.KEYEVENTF_KEYUP : 0) | (unicode ? Native.KEYEVENTF_UNICODE : 0) | (Extended.Contains(vk) ? Native.KEYEVENTF_EXTENDEDKEY : 0);
            return new Native.INPUT { type = Native.INPUT_KEYBOARD, u = new Native.InputUnion { ki = new Native.KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } } };
        }

        static Native.INPUT MouseInput(uint flags, int dx = 0, int dy = 0, int data = 0) =>
            new Native.INPUT { type = Native.INPUT_MOUSE, u = new Native.InputUnion { mi = new Native.MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags } } };

        void Modifiers(IEnumerable<string> mods, bool up)
        {
            foreach (var mod in mods)
            {
                var vk = Modifier(mod);
                if (vk != 0) Send(KeyInput(vk, up));
            }
        }

        public void Tap(ushort vk, IEnumerable<string> mods = null)
        {
            var held = mods?.ToList() ?? new List<string>();
            Modifiers(held, false);
            Send(KeyInput(vk, false));
            Thread.Sleep(10);
            Send(KeyInput(vk, true));
            Modifiers(held, true);
            Thread.Sleep(10);
        }

        public void Move(double x, double y, int settle = 30)
        {
            var screen = Native.VirtualScreen();
            var ax = (int)Math.Round((x - screen.X) * 65535 / Math.Max(screen.Width - 1, 1));
            var ay = (int)Math.Round((y - screen.Y) * 65535 / Math.Max(screen.Height - 1, 1));
            Send(MouseInput(Native.MOUSEEVENTF_MOVE | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK, ax, ay));
            Thread.Sleep(settle);
        }

        public void Click(double x, double y, bool right, int count, List<string> mods)
        {
            Move(x, y);
            Modifiers(mods, false);
            var (down, up) = right ? (Native.MOUSEEVENTF_RIGHTDOWN, Native.MOUSEEVENTF_RIGHTUP) : (Native.MOUSEEVENTF_LEFTDOWN, Native.MOUSEEVENTF_LEFTUP);
            for (var i = 0; i < count; i++)
            {
                Send(MouseInput(down));
                Thread.Sleep(20);
                Send(MouseInput(up));
                Thread.Sleep(20);
            }
            Modifiers(mods, true);
        }

        public void Drag(double fromX, double fromY, double toX, double toY, List<string> mods)
        {
            Move(fromX, fromY);
            Modifiers(mods, false);
            Send(MouseInput(Native.MOUSEEVENTF_LEFTDOWN));
            Thread.Sleep(100);
            const int steps = 20;
            for (var step = 1; step <= steps; step++)
            {
                var t = (double)step / steps;
                Move(fromX + (toX - fromX) * t, fromY + (toY - fromY) * t, 15);
            }
            Thread.Sleep(300);
            Send(MouseInput(Native.MOUSEEVENTF_LEFTUP));
            Modifiers(mods, true);
            Thread.Sleep(100);
        }

        public void Scroll(double x, double y, string direction, int notches)
        {
            Move(x, y);
            var (flag, sign) = direction switch
            {
                "up" => (Native.MOUSEEVENTF_WHEEL, 1), "down" => (Native.MOUSEEVENTF_WHEEL, -1),
                "left" => (Native.MOUSEEVENTF_HWHEEL, -1), _ => (Native.MOUSEEVENTF_HWHEEL, 1),
            };
            for (var i = 0; i < notches; i++)
            {
                Send(MouseInput(flag, data: 120 * sign));
                Thread.Sleep(20);
            }
            Thread.Sleep(100);
        }

        public void Key(string name, List<string> mods)
        {
            if (!Keys.TryGetValue(name, out var vk)) throw new Failure("this guest's keyboard has no key " + name);
            Tap(vk, mods);
        }

        /// Each UTF-16 unit as a Unicode key event, whatever the keyboard layout; Return for a newline.
        public void Type(string text)
        {
            for (var i = 0; i < text.Length; i++)
            {
                var c = text[i];
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') continue;
                if (c == '\r' || c == '\n') { Tap(0x0D); continue; }
                Send(KeyInput(0, false, true, c), KeyInput(0, true, true, c));
                Thread.Sleep(8);
            }
            Thread.Sleep(50);
        }
    }

    // MARK: Win32

    static class Native
    {
        public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
        public const uint KEYEVENTF_EXTENDEDKEY = 0x1, KEYEVENTF_KEYUP = 0x2, KEYEVENTF_UNICODE = 0x4;
        public const uint MOUSEEVENTF_MOVE = 0x1, MOUSEEVENTF_LEFTDOWN = 0x2, MOUSEEVENTF_LEFTUP = 0x4, MOUSEEVENTF_RIGHTDOWN = 0x8,
            MOUSEEVENTF_RIGHTUP = 0x10, MOUSEEVENTF_WHEEL = 0x800, MOUSEEVENTF_HWHEEL = 0x1000, MOUSEEVENTF_VIRTUALDESK = 0x4000,
            MOUSEEVENTF_ABSOLUTE = 0x8000;

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT { public int dx, dy, mouseData; public uint dwFlags, time; public IntPtr dwExtraInfo; }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

        [StructLayout(LayoutKind.Sequential)]
        public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }

        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public InputUnion u; }

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder name, int size);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out RECT value, int size);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

        delegate bool EnumWindowsProc(IntPtr window, IntPtr data);

        const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14;

        public static Rect VirtualScreen() =>
            new Rect(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));

        public static string ClassName(IntPtr window)
        {
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            return name.ToString();
        }

        /// The visible top-level windows, topmost first: their handle, the frame DWM draws (no
        /// invisible resize borders), and whether DWM has them cloaked (on another desktop, or not
        /// yet shown).
        public static List<(IntPtr, Rect, bool)> TopWindows()
        {
            var windows = new List<(IntPtr, Rect, bool)>();
            EnumWindows((window, _) =>
            {
                if (!IsWindowVisible(window)) return true;
                if (DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT r, Marshal.SizeOf(typeof(RECT))) != 0) return true;
                DwmGetWindowAttribute(window, DWMWA_CLOAKED, out int cloaked, sizeof(int));
                var bounds = new Rect(r.Left, r.Top, Math.Max(0, r.Right - r.Left), Math.Max(0, r.Bottom - r.Top));
                if (bounds.Width > 0 && bounds.Height > 0) windows.Add((window, bounds, cloaked != 0));
                return true;
            }, IntPtr.Zero);
            return windows;
        }
    }
}
