param(
    [ValidateSet("menu", "one", "five", "all", "check", "resume2")]
    [string]$Mode = "menu",

    [ValidateSet("tier4plus", "tier5", "tier5plus")]
    [string]$TargetTier = "tier5plus"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$nativeCode = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public struct HKRectNative
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public sealed class HKVisualTarget
{
    public int X;
    public int Y;
    public int Width;
    public int Height;
    public int PixelCount;

    public Point Center
    {
        get { return new Point(X + Width / 2, Y + Height / 2); }
    }
}

public sealed class HKMapExitPoints
{
    public readonly Point Research;
    public readonly Point Building;

    public HKMapExitPoints(Point research, Point building)
    {
        Research = research;
        Building = building;
    }

    public bool IsValid
    {
        get { return Research.X >= 0 && Research.Y >= 0 && Building.X >= 0 && Building.Y >= 0; }
    }
}

public static class HKNative
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out HKRectNative rect);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out HKRectNative value, int size);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr SetActiveWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint attachThread, uint attachToThread, bool attach);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int virtualKey);

    public static bool ForceForeground(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        if (IsIconic(hWnd)) ShowWindow(hWnd, 9);

        IntPtr foreground = GetForegroundWindow();
        uint currentThread = GetCurrentThreadId();
        uint foregroundThread = foreground == IntPtr.Zero
            ? 0
            : GetWindowThreadProcessId(foreground, IntPtr.Zero);
        uint targetThread = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
        bool attachedForeground = false;
        bool attachedTarget = false;
        try
        {
            if (foregroundThread != 0 && foregroundThread != currentThread)
                attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);
            if (targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread)
                attachedTarget = AttachThreadInput(currentThread, targetThread, true);

            ShowWindow(hWnd, 5);
            BringWindowToTop(hWnd);
            SetActiveWindow(hWnd);
            SetForegroundWindow(hWnd);
            return GetForegroundWindow() == hWnd;
        }
        finally
        {
            if (attachedTarget) AttachThreadInput(currentThread, targetThread, false);
            if (attachedForeground) AttachThreadInput(currentThread, foregroundThread, false);
        }
    }

    public static IntPtr FindLargestWindow(string titleFragment)
    {
        IntPtr best = IntPtr.Zero;
        long bestArea = 0;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd)) return true;
            StringBuilder title = new StringBuilder(512);
            GetWindowText(hWnd, title, title.Capacity);
            if (title.ToString().IndexOf(titleFragment, StringComparison.OrdinalIgnoreCase) < 0) return true;

            StringBuilder className = new StringBuilder(256);
            GetClassName(hWnd, className, className.Capacity);
            if (!className.ToString().Equals("Chrome_WidgetWin_1", StringComparison.Ordinal)) return true;

            Rectangle bounds = GetExtendedBounds(hWnd);
            long area = (long)bounds.Width * (long)bounds.Height;
            if (area > bestArea)
            {
                best = hWnd;
                bestArea = area;
            }
            return true;
        }, IntPtr.Zero);

        return best;
    }

    private static bool SafeMapClickHasClearance(int[,] integral, int x, int y, int inner, int outer)
    {
        int innerCount = SafeMapRectangleSum(integral, x - inner, y - inner,
            x + inner + 1, y + inner + 1);
        if (innerCount != (2 * inner + 1) * (2 * inner + 1)) return false;
        int outerCount = SafeMapRectangleSum(integral, x - outer, y - outer,
            x + outer + 1, y + outer + 1);
        return outerCount * 100 >= (2 * outer + 1) * (2 * outer + 1) * 95;
    }

    public static Rectangle GetExtendedBounds(IntPtr hWnd)
    {
        HKRectNative rect;
        try
        {
            const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
            if (DwmGetWindowAttribute(hWnd, DWMWA_EXTENDED_FRAME_BOUNDS, out rect, Marshal.SizeOf(typeof(HKRectNative))) == 0)
            {
                return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
            }
        }
        catch { }

        if (!GetWindowRect(hWnd, out rect)) return Rectangle.Empty;
        return Rectangle.FromLTRB(rect.Left, rect.Top, rect.Right, rect.Bottom);
    }

    public static Bitmap Capture(Rectangle bounds)
    {
        Bitmap bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
        }
        return bitmap;
    }

    public static Point[] FindTierOneMarkers(Bitmap bitmap)
    {
        Rectangle mapArea = new Rectangle(
            (int)Math.Round(55.0 * bitmap.Width / 1920.0),
            (int)Math.Round(170.0 * bitmap.Height / 1040.0),
            (int)Math.Round(1289.0 * bitmap.Width / 1920.0),
            (int)Math.Round(795.0 * bitmap.Height / 1040.0));

        // At the initial map zoom the filter markers are small gold dots.
        List<Point> smallMarkers = new List<Point>();
        // Two observed marker fills. Keep the tight tolerance around each
        // instead of widening a gold range that could match interface art.
        Color[] smallMarkerColors = new Color[] {
            Color.FromArgb(228, 189, 107),
            Color.FromArgb(215, 193, 116)
        };
        foreach (Color markerColor in smallMarkerColors)
        {
            HKVisualTarget[] smallComponents = FindColorComponents(bitmap, markerColor, 3, mapArea);
            foreach (HKVisualTarget component in smallComponents)
            {
                if (component.PixelCount >= 14 && component.PixelCount <= 80
                    && component.Width >= 4 && component.Width <= 12
                    && component.Height >= 4 && component.Height <= 12)
                {
                    Point center = component.Center;
                    if (!smallMarkers.Contains(center)) smallMarkers.Add(center);
                }
            }
        }

        // Selecting a building makes the game centre/zoom the map. The same
        // filtered objects then become larger teardrop pins with a pale band.
        List<Point> largeMarkers = new List<Point>();
        HKVisualTarget[] largeComponents = FindColorComponents(bitmap, Color.FromArgb(231, 211, 155), 3, mapArea);
        int maximumLargeWidth = Math.Max(36, bitmap.Width / 10);
        foreach (HKVisualTarget component in largeComponents)
        {
            // Map zoom changes the pin's pixel size. Check the pale band's
            // proportions and colour coverage instead of a fixed pixel count.
            if (component.Width < 20 || component.Width > maximumLargeWidth
                || component.Height < 1) continue;
            double aspect = (double)component.Width / component.Height;
            double coverage = (double)component.PixelCount / (component.Width * component.Height);
            if (aspect >= 2.3 && aspect <= 3.8 && coverage >= 0.48 && coverage <= 0.85)
            {
                int largeClickOffset = Math.Max(5, (int)Math.Round(component.Width / 4.0));
                largeMarkers.Add(new Point(component.Center.X, component.Center.Y + largeClickOffset));
            }
        }

        List<Point> markers = smallMarkers.Count > 0 ? smallMarkers : largeMarkers;

        markers.Sort(delegate(Point a, Point b)
        {
            int byY = a.Y.CompareTo(b.Y);
            return byY != 0 ? byY : a.X.CompareTo(b.X);
        });
        return markers.ToArray();
    }

    public static HKMapExitPoints FindSafeMapExitPoints(Bitmap bitmap)
    {
        int width = bitmap.Width;
        int height = bitmap.Height;
        // Selecting a building can re-centre the larger-than-screen map to a
        // different district. Search the whole unobstructed visible map, not
        // one narrow strip that may contain no sufficiently wide road after
        // that movement. These bounds exclude every fixed interface panel.
        int x0 = Math.Max(0, (int)Math.Round(140.0 * width / 1920.0));
        int y0 = Math.Max(0, (int)Math.Round(190.0 * height / 1040.0));
        // The larger building panel starts near x=1260 on the reported screen.
        // Keep the entire clearance patch to its left, including at 125% UI.
        int x1 = Math.Min(width, (int)Math.Round(1200.0 * width / 1920.0));
        int y1 = Math.Min(height, (int)Math.Round(900.0 * height / 1040.0));
        int roiWidth = x1 - x0;
        int roiHeight = y1 - y0;
        // Preserve the previous fallback's per-click clearance: a completely
        // road-coloured 13x13 square and at least 95% of its 17x17 surround.
        // Select both actual click centres independently; never add an
        // unchecked offset to the first point.
        int inner = Math.Max(4, (int)Math.Round(6.0 * width / 1920.0));
        int outer = inner + Math.Max(2, (int)Math.Round(2.0 * width / 1920.0));
        Point invalid = new Point(-1, -1);
        if (roiWidth <= 2 * outer + 1 || roiHeight <= 2 * outer + 1)
            return new HKMapExitPoints(invalid, invalid);

        int[,] integral = new int[roiHeight + 1, roiWidth + 1];
        Rectangle lockRect = new Rectangle(0, 0, width, height);
        BitmapData bits = bitmap.LockBits(lockRect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int stride = Math.Abs(bits.Stride);
            byte[] data = new byte[stride * height];
            Marshal.Copy(bits.Scan0, data, 0, data.Length);
            for (int ry = 0; ry < roiHeight; ry++)
            {
                int rowSum = 0;
                int sourceRow = (y0 + ry) * stride;
                for (int rx = 0; rx < roiWidth; rx++)
                {
                    int offset = sourceRow + (x0 + rx) * 3;
                    int b = data[offset];
                    int g = data[offset + 1];
                    int r = data[offset + 2];
                    if (IsSafeMapRoad(r, g, b)) rowSum++;
                    integral[ry + 1, rx + 1] = integral[ry, rx + 1] + rowSum;
                }
            }
        }
        finally { bitmap.UnlockBits(bits); }

        int wantedX = (int)Math.Round(1200.0 * width / 1920.0) - x0;
        int wantedY = (int)Math.Round(650.0 * height / 1040.0) - y0;
        long bestScore = Int64.MaxValue;
        Point best = invalid;
        List<Point> candidates = new List<Point>();

        for (int y = outer; y < roiHeight - outer; y++)
        {
            for (int x = outer; x < roiWidth - outer; x++)
            {
                if (!SafeMapClickHasClearance(integral, x, y, inner, outer)) continue;
                candidates.Add(new Point(x0 + x, y0 + y));

                long dx = x - wantedX;
                long dy = y - wantedY;
                long score = dx * dx + dy * dy;
                if (score < bestScore)
                {
                    bestScore = score;
                    best = new Point(x0 + x, y0 + y);
                }
            }
        }
        if (best.X < 0) return new HKMapExitPoints(invalid, invalid);

        // Prefer the familiar small movement, but permit any direction that
        // actually fits the road. If only one centre is safe, two separate
        // clicks there are valid too; no synthetic second coordinate is used.
        Point second = best;
        int preferredX = best.X + (int)Math.Round(7.0 * width / 1920.0);
        int preferredY = best.Y + (int)Math.Round(5.0 * height / 1040.0);
        bestScore = Int64.MaxValue;
        foreach (Point candidate in candidates)
        {
            if (candidates.Count > 1 && candidate == best) continue;
            long dx = candidate.X - preferredX;
            long dy = candidate.Y - preferredY;
            long score = dx * dx + dy * dy;
            if (score < bestScore)
            {
                bestScore = score;
                second = candidate;
            }
        }
        return new HKMapExitPoints(best, second);
    }

    private static bool IsSafeMapRoad(int r, int g, int b)
    {
        return r >= 86 && r <= 112
            && g >= 87 && g <= 114
            && b >= 96 && b <= 124
            && Math.Abs(r - g) <= 7
            && b - r >= 6 && b - r <= 22;
    }

    private static int SafeMapRectangleSum(int[,] integral, int left, int top, int right, int bottom)
    {
        return integral[bottom, right] - integral[top, right]
            - integral[bottom, left] + integral[top, left];
    }

    private static HKVisualTarget[] FindColorComponents(Bitmap bitmap, Color target, int tolerance, Rectangle searchArea)
    {
        int width = bitmap.Width;
        int height = bitmap.Height;
        int x0 = Math.Max(0, searchArea.Left);
        int x1 = Math.Min(width - 1, searchArea.Right - 1);
        int y0 = Math.Max(0, searchArea.Top);
        int y1 = Math.Min(height - 1, searchArea.Bottom - 1);

        Rectangle lockRect = new Rectangle(0, 0, width, height);
        BitmapData bits = bitmap.LockBits(lockRect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        HashSet<int> matching = new HashSet<int>();
        try
        {
            int stride = Math.Abs(bits.Stride);
            byte[] data = new byte[stride * height];
            Marshal.Copy(bits.Scan0, data, 0, data.Length);
            for (int y = y0; y <= y1; y++)
            {
                int row = y * stride;
                for (int x = x0; x <= x1; x++)
                {
                    int offset = row + x * 3;
                    int b = data[offset];
                    int g = data[offset + 1];
                    int r = data[offset + 2];
                    if (Math.Abs(r - target.R) <= tolerance && Math.Abs(g - target.G) <= tolerance && Math.Abs(b - target.B) <= tolerance)
                    {
                        matching.Add(y * width + x);
                    }
                }
            }
        }
        finally
        {
            bitmap.UnlockBits(bits);
        }

        List<HKVisualTarget> result = new List<HKVisualTarget>();
        Stack<int> stack = new Stack<int>();
        while (matching.Count > 0)
        {
            int seed = 0;
            foreach (int value in matching) { seed = value; break; }
            matching.Remove(seed);
            stack.Push(seed);

            int count = 0;
            int minX = Int32.MaxValue;
            int maxX = Int32.MinValue;
            int minY = Int32.MaxValue;
            int maxY = Int32.MinValue;
            while (stack.Count > 0)
            {
                int current = stack.Pop();
                int cy = current / width;
                int cx = current - cy * width;
                count++;
                minX = Math.Min(minX, cx);
                maxX = Math.Max(maxX, cx);
                minY = Math.Min(minY, cy);
                maxY = Math.Max(maxY, cy);

                for (int dy = -1; dy <= 1; dy++)
                {
                    for (int dx = -1; dx <= 1; dx++)
                    {
                        if (dx == 0 && dy == 0) continue;
                        int nx = cx + dx;
                        int ny = cy + dy;
                        if (nx < x0 || nx > x1 || ny < y0 || ny > y1) continue;
                        int key = ny * width + nx;
                        if (matching.Remove(key)) stack.Push(key);
                    }
                }
            }

            if (count >= 8)
            {
                result.Add(new HKVisualTarget {
                    X = minX,
                    Y = minY,
                    Width = maxX - minX + 1,
                    Height = maxY - minY + 1,
                    PixelCount = count
                });
            }
        }
        return result.ToArray();
    }

    public static Point FindBuildingResearchButton(Bitmap bitmap)
    {
        Rectangle area = new Rectangle(
            (int)Math.Round(1800.0 * bitmap.Width / 1920.0),
            (int)Math.Round(220.0 * bitmap.Height / 1040.0),
            (int)Math.Round(112.0 * bitmap.Width / 1920.0),
            (int)Math.Round(250.0 * bitmap.Height / 1040.0));

        // This is the white HOME pictogram inside the gold circular button in
        // the building header.  Room-action buttons are outside this narrow
        // area and are deliberately never considered.
        HKVisualTarget[] components = FindColorComponents(bitmap, Color.White, 45, area);
        Point candidate = new Point(-1, -1);
        int candidateCount = 0;
        foreach (HKVisualTarget component in components)
        {
            if (component.PixelCount < 140 || component.PixelCount > 420) continue;
            if (component.Width < 16 || component.Width > 30) continue;
            if (component.Height < 17 || component.Height > 32) continue;
            double aspect = (double)component.Width / component.Height;
            double density = (double)component.PixelCount / (component.Width * component.Height);
            if (aspect < 0.72 || aspect > 1.25) continue;
            if (density < 0.38 || density > 0.62) continue;

            Point center = component.Center;
            if (!HasBuildingResearchGoldRing(bitmap, center, component.Height)) continue;
            candidate = center;
            candidateCount++;
        }

        // More than one match is just as unsafe as no match: never guess.
        return candidateCount == 1 ? candidate : new Point(-1, -1);
    }

    private static bool HasBuildingResearchGoldRing(Bitmap bitmap, Point center, int componentHeight)
    {
        double innerRadius = 0.55 * componentHeight;
        double outerRadius = 1.30 * componentHeight;
        double innerSquared = innerRadius * innerRadius;
        double outerSquared = outerRadius * outerRadius;
        int radius = (int)Math.Ceiling(outerRadius);
        int total = 0;
        int[] quadrants = new int[4];

        for (int dy = -radius; dy <= radius; dy++)
        {
            int y = center.Y + dy;
            if (y < 0 || y >= bitmap.Height) continue;
            for (int dx = -radius; dx <= radius; dx++)
            {
                int x = center.X + dx;
                if (x < 0 || x >= bitmap.Width) continue;
                double distanceSquared = dx * dx + dy * dy;
                if (distanceSquared < innerSquared || distanceSquared > outerSquared) continue;

                Color pixel = bitmap.GetPixel(x, y);
                bool gold = pixel.R >= 120
                    && pixel.G >= 55 && pixel.G <= 205
                    && pixel.B <= 140
                    && pixel.R - pixel.B >= 45
                    && pixel.G - pixel.B >= 10;
                if (!gold) continue;

                total++;
                int quadrant = (dy < 0 ? 0 : 2) + (dx < 0 ? 0 : 1);
                quadrants[quadrant]++;
            }
        }

        return total >= 250
            && quadrants[0] >= 45 && quadrants[1] >= 45
            && quadrants[2] >= 45 && quadrants[3] >= 45;
    }

    public static Point FindActionButton(Bitmap bitmap, string kind)
    {
        Rectangle area = new Rectangle(
            (int)Math.Round(1200.0 * bitmap.Width / 1920.0),
            (int)Math.Round(250.0 * bitmap.Height / 1040.0),
            (int)Math.Round(710.0 * bitmap.Width / 1920.0),
            (int)Math.Round(710.0 * bitmap.Height / 1040.0));

        HKVisualTarget[] components = FindColorComponents(bitmap, Color.FromArgb(202, 177, 91), 3, area);
        HKVisualTarget best = null;
        foreach (HKVisualTarget component in components)
        {
            if (component.Height < 35 || component.Height > 78 || component.Width < 90) continue;
            double aspect = (double)component.Width / component.Height;
            double density = (double)component.PixelCount / (component.Width * component.Height);
            bool match = false;

            if (kind == "research")
                match = component.PixelCount >= 900 && density < 0.18 && aspect >= 9.0;
            else if (kind == "fight")
                match = component.PixelCount >= 650 && density < 0.18 && aspect >= 6.0 && aspect < 9.0;
            else if (kind == "renovation")
                match = component.PixelCount >= 400 && density < 0.18 && aspect >= 2.5 && aspect < 5.0;

            if (match && (best == null || component.PixelCount > best.PixelCount)) best = component;
        }
        return best == null ? new Point(-1, -1) : best.Center;
    }

    public static bool IsRewardVisible(Bitmap bitmap)
    {
        Point prompt;
        return GetRewardAppearance(bitmap, out prompt);
    }

    public static Point FindRewardContinuePrompt(Bitmap bitmap)
    {
        Point prompt;
        GetRewardAppearance(bitmap, out prompt);
        return prompt;
    }

    private static double RewardDarkFraction(byte[] data, int stride, Rectangle area)
    {
        if (area.Width <= 0 || area.Height <= 0) return 0.0;
        int dark = 0;
        for (int y = area.Top; y < area.Bottom; y++)
        {
            for (int x = area.Left; x < area.Right; x++)
            {
                int offset = y * stride + x * 3;
                if (data[offset] <= 35 && data[offset + 1] <= 35 && data[offset + 2] <= 35) dark++;
            }
        }
        return (double)dark / (area.Width * area.Height);
    }

    private static bool GetRewardAppearance(Bitmap bitmap, out Point prompt)
    {
        // No OCR or phrase templates: the same reward layout is used across
        // languages. A ribbon alone is not evidence that input is ready.
        prompt = new Point(-1, -1);
        int width = bitmap.Width;
        int height = bitmap.Height;
        double scaleX = width / 1920.0;
        double scaleY = height / 1040.0;
        int stride;
        byte[] data;
        Rectangle lockRect = new Rectangle(0, 0, width, height);
        BitmapData bits = bitmap.LockBits(lockRect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            stride = Math.Abs(bits.Stride);
            data = new byte[stride * height];
            Marshal.Copy(bits.Scan0, data, 0, data.Length);
        }
        finally { bitmap.UnlockBits(bits); }

        int x0 = (int)Math.Round(0.30 * width);
        int x1 = (int)Math.Round(0.70 * width);
        int y0 = (int)Math.Round(0.28 * height);
        int y1 = (int)Math.Round(0.70 * height);
        int[] rowCount = new int[height];
        int[] rowLeft = new int[height];
        int[] rowRight = new int[height];
        for (int y = y0; y < y1; y++)
        {
            rowLeft[y] = width;
            rowRight[y] = -1;
            for (int x = x0; x < x1; x++)
            {
                int offset = y * stride + x * 3;
                int b = data[offset], g = data[offset + 1], r = data[offset + 2];
                if (r >= 180 && g >= 105 && g <= 235 && b <= 110 && r - g >= 15 && g - b >= 55)
                {
                    rowCount[y]++;
                    if (x < rowLeft[y]) rowLeft[y] = x;
                    if (x > rowRight[y]) rowRight[y] = x;
                }
            }
        }

        int layouts = 0;
        int minimumRowGold = (int)Math.Round(0.06 * width);
        for (int start = y0; start < y1; )
        {
            if (rowCount[start] < minimumRowGold) { start++; continue; }
            int end = start, last = start, gaps = 0, qualified = 0, gold = 0;
            while (end < y1 && gaps <= 2)
            {
                if (rowCount[end] >= minimumRowGold)
                {
                    last = end;
                    gaps = 0;
                    qualified++;
                    gold += rowCount[end];
                }
                else gaps++;
                end++;
            }
            int left = width, right = -1;
            for (int y = start; y <= last; y++)
            {
                if (rowLeft[y] < left) left = rowLeft[y];
                if (rowRight[y] > right) right = rowRight[y];
            }
            int bandHeight = last - start + 1;
            if (qualified >= (int)Math.Round(0.018 * height)
                && bandHeight >= (int)Math.Round(0.022 * height)
                && bandHeight <= (int)Math.Round(0.13 * height)
                && gold >= Math.Max(1500, (int)Math.Round(3500 * scaleX * scaleY))
                && right - left + 1 >= (int)Math.Round(0.10 * width)
                && Math.Abs((left + right) / 2.0 - width / 2.0) <= 0.055 * width)
            {
                int top = last + (int)Math.Round(0.015 * height);
                int bottom = last + (int)Math.Round(0.095 * height);
                if (bottom < height)
                {
                    Rectangle leftBand = Rectangle.FromLTRB((int)Math.Round(0.12 * width), top,
                        (int)Math.Round(0.35 * width), bottom);
                    Rectangle rightBand = Rectangle.FromLTRB((int)Math.Round(0.65 * width), top,
                        (int)Math.Round(0.88 * width), bottom);
                    if (RewardDarkFraction(data, stride, leftBand) >= 0.90
                        && RewardDarkFraction(data, stride, rightBand) >= 0.90) layouts++;
                }
            }
            start = end;
        }
        if (layouts != 1) return false;

        Rectangle area = Rectangle.FromLTRB((int)Math.Round(0.25 * width), (int)Math.Round(0.82 * height),
            (int)Math.Round(0.75 * width), (int)Math.Round(0.96 * height));
        int goldCount = 0, minX = width, minY = height, maxX = -1, maxY = -1;
        for (int y = area.Top; y < area.Bottom; y++)
        {
            for (int x = area.Left; x < area.Right; x++)
            {
                int offset = y * stride + x * 3;
                int b = data[offset], g = data[offset + 1], r = data[offset + 2];
                // A gold hue range tolerates the prompt's brightness animation.
                if (r >= 120 && g >= 95 && g <= 240 && b <= 180
                    && r - g >= 8 && r - g <= 70 && g - b >= 30)
                {
                    goldCount++;
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (goldCount == 0) return true;
        int spanX = maxX - minX + 1, spanY = maxY - minY + 1;
        double density = (double)goldCount / (spanX * spanY);
        int centerX = (minX + maxX) / 2;
        if (goldCount >= Math.Max(30, (int)Math.Round(50 * scaleX * scaleY))
            && spanX >= Math.Max(8, (int)Math.Round(12 * scaleX))
            && spanY >= Math.Max(5, (int)Math.Round(8 * scaleY))
            && spanY <= (int)Math.Round(48 * scaleY)
            && density >= 0.06 && density <= 0.65
            && Math.Abs(centerX - width / 2.0) <= 0.06 * width
            && RewardDarkFraction(data, stride, area) >= 0.75)
            prompt = new Point(centerX, (minY + maxY) / 2);
        return true;
    }

    public static bool IsRewardOverlayVisible(Bitmap bitmap)
    {
        return IsRewardVisible(bitmap);
    }

    public static bool IsRewardDismissed(Bitmap bitmap)
    {
        // Missing pixels alone cannot prove dismissal: a black/fading capture
        // must never advance the upgrade loop. Require the returned form.
        return !IsRewardOverlayVisible(bitmap) && FindActionButton(bitmap, "research").X >= 0;
    }

    public static bool IsTierTwoActive(Bitmap bitmap)
    {
        int width = bitmap.Width;
        int height = bitmap.Height;
        Rectangle area = new Rectangle(
            Math.Max(0, (int)Math.Round(1620.0 * width / 1920.0)),
            Math.Max(0, (int)Math.Round(215.0 * height / 1040.0)),
            Math.Max(1, (int)Math.Round(80.0 * width / 1920.0)),
            Math.Max(1, (int)Math.Round(70.0 * height / 1040.0)));
        if (area.Right > width) area.Width = width - area.Left;
        if (area.Bottom > height) area.Height = height - area.Top;
        if (area.Width <= 0 || area.Height <= 0) return false;

        int greenCount = 0;
        Rectangle lockRect = new Rectangle(0, 0, width, height);
        BitmapData bits = bitmap.LockBits(lockRect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try
        {
            int stride = Math.Abs(bits.Stride);
            byte[] data = new byte[stride * height];
            Marshal.Copy(bits.Scan0, data, 0, data.Length);
            for (int y = area.Top; y < area.Bottom; y++)
            {
                int row = y * stride;
                for (int x = area.Left; x < area.Right; x++)
                {
                    int offset = row + x * 3;
                    int b = data[offset];
                    int g = data[offset + 1];
                    int r = data[offset + 2];
                    if (g > 150 && g - r > 55 && g - b > 55) greenCount++;
                }
            }
        }
        finally { bitmap.UnlockBits(bits); }

        int minimumGreen = Math.Max(350, (int)Math.Round(450.0 * width / 1920.0 * height / 1040.0));
        return greenCount >= minimumGreen;
    }

    public static int SystemLeftClick(
        int x,
        int y,
        IntPtr expectedForegroundWindow)
    {
        if (expectedForegroundWindow != IntPtr.Zero && GetForegroundWindow() != expectedForegroundWindow) return 0;
        if ((GetAsyncKeyState(0x78) & 0x8000) != 0) return -1;
        if (!SetCursorPos(x, y)) return 0;
        System.Threading.Thread.Sleep(20);
        if (expectedForegroundWindow != IntPtr.Zero && GetForegroundWindow() != expectedForegroundWindow) return 0;
        if ((GetAsyncKeyState(0x78) & 0x8000) != 0) return -1;
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(30);
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
        return 1;
    }

}
'@

Add-Type -TypeDefinition $nativeCode -ReferencedAssemblies System.Drawing

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogRoot = Join-Path $script:Root "logs"
$script:RunName = "run_{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"), $PID
$script:LogDirectory = Join-Path $script:LogRoot $script:RunName
$script:LogFile = Join-Path $script:LogDirectory ($script:RunName + ".log")
$script:SessionLock = $null
$settingsPath = Join-Path $script:Root "settings.json"

if (-not (Test-Path $script:LogDirectory)) {
    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
}
if (-not (Test-Path $settingsPath)) {
    throw "settings.json is missing. Extract the complete archive and run again."
}

$script:Settings = Get-Content -Raw -Path $settingsPath | ConvertFrom-Json

foreach ($settingName in @("MaxBuildingsPerRun", "PanelTimeoutSeconds", "StateTimeoutSeconds", "FightTimeoutSeconds")) {
    $property = $script:Settings.PSObject.Properties[$settingName]
    if ($null -eq $property -or [int]$property.Value -le 0) {
        throw ("settings.json contains an invalid or missing '{0}'." -f $settingName)
    }
}
$script:StopRequested = $false
$script:Paused = $true
$script:PreviousF8 = $false
$script:PreviousF9 = $false
$script:GameHandle = [IntPtr]::Zero
$script:Bounds = [System.Drawing.Rectangle]::Empty
$script:SilentConsoleExit = $false
$script:LastBuildingTargetReached = $false
$script:WaitedForGameTab = $false
$script:ExitCode = 0
$script:TargetTransition = 6
$script:TargetLabel = "Tier 5+"
if ($TargetTier -eq "tier4plus") {
    $script:TargetTransition = 4
    $script:TargetLabel = "Tier 4+"
} elseif ($TargetTier -eq "tier5") {
    $script:TargetTransition = 5
    $script:TargetLabel = "Tier 5"
}
if ($Mode -eq "resume2") {
    # This dedicated recovery file belongs only to the previously interrupted
    # Tier-2 -> Tier-5+ run. Mass target launchers never use this mode.
    $script:TargetTransition = 6
    $script:TargetLabel = "Tier 5+"
}

function Write-HKLog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

function Remove-HKOldMapTraces {
    param([int]$BuildingNumber)
    # Preserve the latest five building pairs.
    # Error PNGs and the complete text log are never removed here.
    try {
        $pattern = "^" + [regex]::Escape($script:RunName) + "_building_([0-9]+)_(before_select|after_select)\.png$"
        foreach ($file in @(Get-ChildItem -LiteralPath $script:LogDirectory -File)) {
            if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($file.Name -notmatch $pattern) { continue }
            $number = [int]$Matches[1]
            if ($number -lt ($BuildingNumber - 4)) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
        }
    }
    catch { Write-Host ("Diagnostic cleanup skipped: " + $_.Exception.Message) }
}

function Remove-HKOldSessionDiagnostics {
    # Flat logs from previous releases are deliberately left alone. They are
    # not part of this owned session format and may contain the user's evidence.
    try {
        $sessions = @()
        $sessionPattern = '^run_[0-9]{8}_[0-9]{6}_[0-9]{3}_[0-9]+$'
        foreach ($directory in @(Get-ChildItem -LiteralPath $script:LogRoot -Directory)) {
            if ($directory.Name -notmatch $sessionPattern) { continue }
            if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $logPath = Join-Path $directory.FullName ($directory.Name + '.log')
            $lockPath = Join-Path $directory.FullName 'session.lock'
            if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { continue }
            if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { continue }
            $firstLine = Get-Content -LiteralPath $logPath -TotalCount 1 -ErrorAction Stop
            if ($firstLine -notmatch 'Starting Hamster King Tier Autopilot v') { continue }
            $failed = [bool](Select-String -LiteralPath $logPath -Pattern 'STOPPED SAFELY:|FATAL ERROR:' -Quiet)
            $sessions += [pscustomobject]@{ Directory = $directory; Failed = $failed }
        }
        $sessions = @($sessions | Sort-Object { $_.Directory.Name } -Descending)
        $kept = @{}
        $kept[$script:RunName] = $true
        foreach ($session in @($sessions | Select-Object -First 5)) {
            $kept[$session.Directory.Name] = $true
        }
        $latestFailed = @($sessions | Where-Object { $_.Failed } | Select-Object -First 1)
        if ($latestFailed.Count -gt 0) { $kept[$latestFailed[0].Directory.Name] = $true }
        foreach ($session in $sessions) {
            $directory = $session.Directory
            if ($kept.ContainsKey($directory.Name)) { continue }
            $cleanupLock = $null
            try {
                # An active second instance holds this file open and is skipped.
                $cleanupLock = [System.IO.File]::Open(
                    (Join-Path $directory.FullName 'session.lock'),
                    [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::None)
                $files = @(Get-ChildItem -LiteralPath $directory.FullName -Force)
                $ownedPattern = '^(?:' + [regex]::Escape($directory.Name) + '\.log|' +
                    [regex]::Escape($directory.Name) + '_building_[0-9]+_(?:before_select|after_select)\.png|' +
                    '(?:unexpected_state|fatal_error|no_markers|marker_check)_[0-9]{8}_[0-9]{6}\.png|session\.lock)$'
                $unknown = @($files | Where-Object {
                    $_.PSIsContainer -or
                    ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $_.Name -notmatch $ownedPattern
                })
                if ($unknown.Count -gt 0) { continue }
                foreach ($file in $files) {
                    if ($file.Name -ne 'session.lock') {
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    }
                }
                $cleanupLock.Dispose()
                $cleanupLock = $null
                Remove-Item -LiteralPath (Join-Path $directory.FullName 'session.lock') -Force -ErrorAction Stop
                # Non-recursive: if an unrecognized/new file appeared, do not delete it.
                [System.IO.Directory]::Delete($directory.FullName, $false)
            }
            catch { Write-Host ("Old diagnostic session left in place: " + $directory.Name) }
            finally { if ($null -ne $cleanupLock) { $cleanupLock.Dispose() } }
        }
    }
    catch { Write-Host ("Diagnostic cleanup skipped: " + $_.Exception.Message) }
}

function Update-HKGeometry {
    $waitingAnnounced = $false
    while (-not $script:StopRequested) {
        $script:GameHandle = [HKNative]::FindLargestWindow("Hamster King")
        if ($script:GameHandle -ne [IntPtr]::Zero) {
            break
        }

        if (-not $waitingAnnounced) {
            $script:WaitedForGameTab = $true
            Write-HKLog "WAITING: the Hamster King tab is open but not currently selected, or its Chrome window is unavailable."
            Write-Host ""
            Write-Host "Select the Hamster King tab in Chrome. The program will detect it and continue automatically."
            Write-Host "No screenshots or game clicks are made while waiting. Press F9 to cancel."
            [console]::Beep(620, 220)
            $waitingAnnounced = $true
        }

        if (([HKNative]::GetAsyncKeyState(0x78) -band 0x8000) -ne 0) {
            $script:StopRequested = $true
            Write-HKLog "F9 received while waiting for the Hamster King tab. Start cancelled without clicks."
            return $false
        }

        Start-Sleep -Milliseconds 250
    }

    if ($script:StopRequested) {
        return $false
    }

    if ($waitingAnnounced) {
        Write-HKLog "Hamster King tab detected. Startup can continue."
    }

    $script:Bounds = [HKNative]::GetExtendedBounds($script:GameHandle)
    if ($script:Bounds.Width -lt 1850 -or $script:Bounds.Width -gt 2000 -or $script:Bounds.Height -lt 990 -or $script:Bounds.Height -gt 1080) {
        throw ("Unexpected game window size: {0}x{1}. Use a maximized Chrome window on a 1920x1080 display, 100% browser zoom, not F11." -f $script:Bounds.Width, $script:Bounds.Height)
    }
    return $true
}

function Set-HKForeground {
    $consoleHandle = [HKNative]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero -and $consoleHandle -ne $script:GameHandle) {
        [void][HKNative]::ShowWindow($consoleHandle, 6)
        Start-Sleep -Milliseconds 250
    }

    if ([HKNative]::IsIconic($script:GameHandle)) {
        [void][HKNative]::ShowWindow($script:GameHandle, 9)
        Start-Sleep -Milliseconds 300
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        [void][HKNative]::ForceForeground($script:GameHandle)
        Start-Sleep -Milliseconds 180
        if ([HKNative]::GetForegroundWindow() -eq $script:GameHandle) {
            Start-Sleep -Milliseconds 500
            return
        }
    }

    throw "Chrome could not be brought to the foreground. Close windows covering the game and try again."
}

function Restore-HKConsole {
    $consoleHandle = [HKNative]::GetConsoleWindow()
    if ($consoleHandle -ne [IntPtr]::Zero) {
        [void][HKNative]::ShowWindow($consoleHandle, 9)
        Start-Sleep -Milliseconds 180
        [void][HKNative]::ForceForeground($consoleHandle)
    }
}

function Get-HKCapture {
    if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
        throw "Screen capture cancelled because Chrome is not the foreground window."
    }
    return [HKNative]::Capture($script:Bounds)
}

function Test-HKHotkeys {
    $f8Down = (([HKNative]::GetAsyncKeyState(0x77) -band 0x8000) -ne 0)
    $f9Down = (([HKNative]::GetAsyncKeyState(0x78) -band 0x8000) -ne 0)

    if ($f9Down -and -not $script:PreviousF9) {
        $script:StopRequested = $true
        $script:Paused = $false
        Write-HKLog "F9 received: emergency stop requested."
        [console]::Beep(420, 250)
    }
    if ($f8Down -and -not $script:PreviousF8 -and -not $script:StopRequested) {
        $script:Paused = -not $script:Paused
        if ($script:Paused) {
            Write-HKLog "Paused. Press F8 to continue or F9 to stop."
            [console]::Beep(700, 160)
        } else {
            Set-HKForeground
            Write-HKLog "Running. Do not move the mouse or switch windows."
            [console]::Beep(900, 160)
        }
    }

    $script:PreviousF8 = $f8Down
    $script:PreviousF9 = $f9Down
}

function Wait-HKReady {
    while ($script:Paused -and -not $script:StopRequested) {
        Test-HKHotkeys
        Start-Sleep -Milliseconds 90
    }
    return (-not $script:StopRequested)
}

function Wait-HKTechnicalDelay {
    param([int]$Milliseconds)
    $remaining = [Math]::Max(0, $Milliseconds)
    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            if (-not (Wait-HKReady)) { return $false }
            continue
        }

        $slice = [Math]::Min(50, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    return (-not $script:StopRequested)
}

function Get-HKFixedActionDelayMilliseconds {
    param(
        [ValidateSet("marker", "home", "research", "fight", "renovation", "reward", "close_research", "close_building")]
        [string]$ActionKind
    )

    # Fixed action-specific post-click pacing only.  There is deliberately no
    # random component or human-behaviour imitation.  A normal Tier-1 ->
    # Tier-5+ building receives exactly 7,000 ms of additional pacing:
    # 180 + 240 + 6 * (160 + 110 + 250 + 520) + 150 + 190.
    switch ($ActionKind) {
        "marker"         { return 180 }
        "home"           { return 240 }
        "research"       { return 160 }
        "fight"          { return 110 }
        "renovation"     { return 250 }
        "reward"         { return 520 }
        "close_research" { return 150 }
        "close_building" { return 190 }
    }
}

function Wait-HKFixedActionPacing {
    param(
        [ValidateSet("marker", "home", "research", "fight", "renovation", "reward", "close_research", "close_building")]
        [string]$ActionKind
    )

    $delayMilliseconds = Get-HKFixedActionDelayMilliseconds $ActionKind
    return (Wait-HKTechnicalDelay $delayMilliseconds)
}

function Invoke-HKLocalClick {
    param([int]$LocalX, [int]$LocalY)
    while (-not $script:StopRequested) {
        if (-not (Wait-HKReady)) { return $false }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Click is waiting because the game is not in the foreground. Return to the game and press F8."
            continue
        }

        $clickResult = [HKNative]::SystemLeftClick(
            $script:Bounds.Left + $LocalX,
            $script:Bounds.Top + $LocalY,
            $script:GameHandle)
        if ($clickResult -eq 1) {
            return $true
        }
        if ($clickResult -eq -1) {
            $script:StopRequested = $true
            $script:Paused = $false
            Write-HKLog "F9 received during cursor positioning: emergency stop requested."
            [console]::Beep(420, 250)
            return $false
        }

        $script:Paused = $true
        Write-HKLog "Mouse click was cancelled because focus changed. Return to the game and press F8 to retry."
    }
    return $false
}

function Invoke-HKNudgedLocalClick {
    param(
        [int]$LocalX,
        [int]$LocalY,
        [int]$StageOffsetX = -12,
        [int]$StageOffsetY = -8,
        [int]$StageDelayMilliseconds = 100,
        [int]$FinalDelayMilliseconds = 140,
        [string]$GuardKind = ""
    )

    while (-not $script:StopRequested) {
        if (-not (Wait-HKReady)) { return $false }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Cursor nudge is waiting because the game is not in the foreground. Return to the game and press F8."
            continue
        }

        $scaledStageX = [int][Math]::Round($StageOffsetX * $script:Bounds.Width / 1920.0)
        $scaledStageY = [int][Math]::Round($StageOffsetY * $script:Bounds.Height / 1040.0)
        $stageX = [Math]::Max(0, [Math]::Min($script:Bounds.Width - 1, $LocalX + $scaledStageX))
        $stageY = [Math]::Max(0, [Math]::Min($script:Bounds.Height - 1, $LocalY + $scaledStageY))

        if (-not ([HKNative]::SetCursorPos($script:Bounds.Left + $stageX, $script:Bounds.Top + $stageY))) {
            return (Stop-HKOnUnexpectedState "Windows could not position the cursor for the guarded micro-movement.")
        }
        if (-not (Wait-HKTechnicalDelay $StageDelayMilliseconds)) { return $false }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Focus changed during the cursor micro-movement. Return to the game and press F8."
            continue
        }

        if (-not ([HKNative]::SetCursorPos($script:Bounds.Left + $LocalX, $script:Bounds.Top + $LocalY))) {
            return (Stop-HKOnUnexpectedState "Windows could not position the cursor on the guarded click target.")
        }
        if (-not (Wait-HKTechnicalDelay $FinalDelayMilliseconds)) { return $false }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Focus changed before the final guarded check. Return to the game and press F8."
            continue
        }

        # A previously issued request can finish during the short cursor
        # movement.  Re-check the source control immediately before mouse-down
        # so a delayed transition can never turn a retry into a click on the
        # next screen.
        if ($GuardKind -ne "") {
            $bitmap = Get-HKCapture
            try {
                if ($GuardKind -eq "reward") {
                    $guardTarget = [HKNative]::FindRewardContinuePrompt($bitmap)
                } elseif ($GuardKind -eq "research") {
                    $guardTarget = [HKNative]::FindActionButton($bitmap, "research")
                } else {
                    return (Stop-HKOnUnexpectedState ("Unknown guarded click kind: {0}." -f $GuardKind))
                }
            }
            finally {
                $bitmap.Dispose()
            }

            if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
                $script:Paused = $true
                Write-HKLog "Focus changed during the final visual check. Return to the game and press F8."
                continue
            }

            $maximumDeltaX = [int][Math]::Round(40.0 * $script:Bounds.Width / 1920.0)
            $maximumDeltaY = [int][Math]::Round(25.0 * $script:Bounds.Height / 1040.0)
            $guardTargetMissing = ($guardTarget.X -lt 0)
            $guardTargetMovedX = ([Math]::Abs($guardTarget.X - $LocalX) -gt $maximumDeltaX)
            $guardTargetMovedY = ([Math]::Abs($guardTarget.Y - $LocalY) -gt $maximumDeltaY)
            if ($guardTargetMissing -or $guardTargetMovedX -or $guardTargetMovedY) {
                Write-HKLog ("Guarded {0} click cancelled because its source control changed during the cursor movement." -f $GuardKind)
                return $false
            }
        }

        Test-HKHotkeys
        if ($script:StopRequested) { return $false }
        if ($script:Paused) {
            Write-HKLog "Guarded click paused before mouse-down. Press F8 to revalidate and retry."
            if (-not (Wait-HKReady)) { return $false }
            continue
        }

        # Do not hand this guarded target to the generic click loop: if focus
        # changes after validation, that loop could wait for F8 and later click
        # without validating the screen again.  A cancelled system click instead
        # restarts this outer loop, including movement and the final guard.
        $clickResult = [HKNative]::SystemLeftClick(
            $script:Bounds.Left + $LocalX,
            $script:Bounds.Top + $LocalY,
            $script:GameHandle)
        if ($clickResult -eq 1) { return $true }
        if ($clickResult -eq -1) {
            $script:StopRequested = $true
            $script:Paused = $false
            Write-HKLog "F9 received during guarded cursor positioning: emergency stop requested."
            [console]::Beep(420, 250)
            return $false
        }

        $script:Paused = $true
        Write-HKLog "Guarded click was cancelled because focus changed. Return to the game and press F8 to retry with a new visual check."
    }
    return $false
}

function Get-HKSafeMapExitPoints {
    $bitmap = Get-HKCapture
    try {
        return [HKNative]::FindSafeMapExitPoints($bitmap)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Wait-HKStableSafeMapExitPoints {
    param([int]$TimeoutSeconds = 5, [int]$StableFrames = 3)
    $remaining = $TimeoutSeconds * 1000
    $pollMs = 150
    $stableChecks = 0
    $invalidPoint = [System.Drawing.Point]::new(-1, -1)
    $invalidPair = [HKMapExitPoints]::new($invalidPoint, $invalidPoint)
    $lastTarget = $invalidPair
    $stableAnchor = $invalidPair
    $requiredChecks = [Math]::Max(1, $StableFrames)
    $maximumStableDeltaX = [Math]::Max(2, [int][Math]::Round(4.0 * $script:Bounds.Width / 1920.0))
    $maximumStableDeltaY = [Math]::Max(2, [int][Math]::Round(4.0 * $script:Bounds.Height / 1040.0))

    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            if (-not (Wait-HKReady)) { return $invalidPair }
            continue
        }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Game lost focus while waiting for the re-centred map to settle: paused automatically."
            [console]::Beep(520, 300)
            continue
        }

        $target = Get-HKSafeMapExitPoints
        if ($target.IsValid) {
            $sameStableTarget = $false
            if ($stableAnchor.IsValid) {
                $sameStableTarget = ([Math]::Abs($target.Research.X - $stableAnchor.Research.X) -le $maximumStableDeltaX) -and
                    ([Math]::Abs($target.Research.Y - $stableAnchor.Research.Y) -le $maximumStableDeltaY) -and
                    ([Math]::Abs($target.Building.X - $stableAnchor.Building.X) -le $maximumStableDeltaX) -and
                    ([Math]::Abs($target.Building.Y - $stableAnchor.Building.Y) -le $maximumStableDeltaY)
            }
            if ($sameStableTarget) {
                $stableChecks++
            } else {
                $stableChecks = 1
                $stableAnchor = $target
            }
            $lastTarget = $target
            if ($stableChecks -ge $requiredChecks) { return $lastTarget }
        } else {
            $stableChecks = 0
            $lastTarget = $invalidPair
            $stableAnchor = $invalidPair
        }

        Start-Sleep -Milliseconds $pollMs
        $remaining -= $pollMs
    }
    return $invalidPair
}

function Wait-HKActionButton {
    param([string]$Kind, [int]$TimeoutSeconds, [int]$StableFrames = 1)
    $remaining = $TimeoutSeconds * 1000
    $pollMs = 150
    $stableChecks = 0
    $lastTarget = [System.Drawing.Point]::new(-1, -1)
    $stableAnchor = [System.Drawing.Point]::new(-1, -1)
    $requiredChecks = [Math]::Max(1, $StableFrames)
    $maximumStableDeltaX = [Math]::Max(2, [int][Math]::Round(6.0 * $script:Bounds.Width / 1920.0))
    $maximumStableDeltaY = [Math]::Max(2, [int][Math]::Round(6.0 * $script:Bounds.Height / 1040.0))
    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            if (-not (Wait-HKReady)) { return [System.Drawing.Point]::new(-1, -1) }
            continue
        }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Game lost focus while waiting for '$Kind': paused automatically."
            [console]::Beep(520, 300)
            continue
        }

        $bitmap = Get-HKCapture
        try {
            if ($Kind -eq "building_research") {
                $target = [HKNative]::FindBuildingResearchButton($bitmap)
            } else {
                $target = [HKNative]::FindActionButton($bitmap, $Kind)
            }
            if ($target.X -ge 0) {
                $sameStableTarget = $false
                if ($stableAnchor.X -ge 0) {
                    $sameStableTarget = ([Math]::Abs($target.X - $stableAnchor.X) -le $maximumStableDeltaX) -and ([Math]::Abs($target.Y - $stableAnchor.Y) -le $maximumStableDeltaY)
                }
                if ($sameStableTarget) {
                    $stableChecks++
                } else {
                    $stableChecks = 1
                    $stableAnchor = $target
                }
                $lastTarget = $target
            } else {
                $stableChecks = 0
                $lastTarget = [System.Drawing.Point]::new(-1, -1)
                $stableAnchor = [System.Drawing.Point]::new(-1, -1)
            }
            if ($stableChecks -ge $requiredChecks) { return $lastTarget }
        }
        finally {
            $bitmap.Dispose()
        }
        Start-Sleep -Milliseconds $pollMs
        $remaining -= $pollMs
    }
    return [System.Drawing.Point]::new(-1, -1)
}

function Wait-HKActionAbsent {
    param([string]$Kind, [int]$TimeoutSeconds)
    $remaining = $TimeoutSeconds * 1000
    $pollMs = 150
    $clearChecks = 0
    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            if (-not (Wait-HKReady)) { return $false }
            continue
        }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            Write-HKLog "Game lost focus while confirming that '$Kind' closed: paused automatically."
            [console]::Beep(520, 300)
            continue
        }

        $bitmap = Get-HKCapture
        try {
            if ($Kind -eq "building_research") {
                $target = [HKNative]::FindBuildingResearchButton($bitmap)
            } else {
                $target = [HKNative]::FindActionButton($bitmap, $Kind)
            }
            if ($target.X -lt 0) { $clearChecks++ } else { $clearChecks = 0 }
            if ($clearChecks -ge 5) { return $true }
        }
        finally {
            $bitmap.Dispose()
        }
        Start-Sleep -Milliseconds $pollMs
        $remaining -= $pollMs
    }
    return $false
}

function Wait-HKRewardPrompt {
    param([int]$TimeoutSeconds)
    $remaining = $TimeoutSeconds * 1000
    $pollMs = 150
    $readyChecks = 0
    $lastPrompt = [System.Drawing.Point]::new(-1, -1)
    $promptAnchor = [System.Drawing.Point]::new(-1, -1)
    $stableDelta = [Math]::Max(3, [int][Math]::Round(6.0 * $script:Bounds.Width / 1920.0))
    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            $readyChecks = 0
            $promptAnchor = [System.Drawing.Point]::new(-1, -1)
            if (-not (Wait-HKReady)) { return [System.Drawing.Point]::new(-1, -1) }
            continue
        }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            $readyChecks = 0
            $promptAnchor = [System.Drawing.Point]::new(-1, -1)
            Write-HKLog "Game lost focus while waiting for the ready reward prompt: paused automatically."
            [console]::Beep(520, 300)
            continue
        }

        $bitmap = Get-HKCapture
        try {
            $prompt = [HKNative]::FindRewardContinuePrompt($bitmap)
            if ($prompt.X -ge 0) {
                if ($promptAnchor.X -ge 0 -and [Math]::Abs($prompt.X - $promptAnchor.X) -le $stableDelta -and [Math]::Abs($prompt.Y - $promptAnchor.Y) -le $stableDelta) {
                    $readyChecks++
                } else {
                    $readyChecks = 1
                    $promptAnchor = $prompt
                }
                $lastPrompt = $prompt
            } else {
                $readyChecks = 0
                $lastPrompt = [System.Drawing.Point]::new(-1, -1)
                $promptAnchor = [System.Drawing.Point]::new(-1, -1)
            }
            if ($readyChecks -ge 3) { return $lastPrompt }
        }
        finally {
            $bitmap.Dispose()
        }
        Start-Sleep -Milliseconds $pollMs
        $remaining -= $pollMs
    }
    return [System.Drawing.Point]::new(-1, -1)
}

function Wait-HKRewardAbsent {
    param([int]$TimeoutSeconds)
    $remaining = $TimeoutSeconds * 1000
    $pollMs = 150
    $clearChecks = 0
    while ($remaining -gt 0 -and -not $script:StopRequested) {
        Test-HKHotkeys
        if ($script:Paused) {
            $clearChecks = 0
            if (-not (Wait-HKReady)) { return $false }
            continue
        }
        if ([HKNative]::GetForegroundWindow() -ne $script:GameHandle) {
            $script:Paused = $true
            $clearChecks = 0
            Write-HKLog "Game lost focus while confirming that the reward closed: paused automatically."
            [console]::Beep(520, 300)
            continue
        }

        $bitmap = Get-HKCapture
        try {
            if ([HKNative]::IsRewardDismissed($bitmap)) { $clearChecks++ } else { $clearChecks = 0 }
            if ($clearChecks -ge 3) { return $true }
        }
        finally {
            $bitmap.Dispose()
        }
        Start-Sleep -Milliseconds $pollMs
        $remaining -= $pollMs
    }
    return $false
}

function Get-HKRewardClickPoint {
    param([System.Drawing.Point]$Prompt, [int]$Attempt)

    $offsets = @(
        [pscustomobject]@{ X = 0; Y = 0 }
        [pscustomobject]@{ X = 10; Y = 3 }
    )
    $selected = $offsets[[Math]::Min([Math]::Max(0, $Attempt), $offsets.Count - 1)]
    $x = $Prompt.X + [int][Math]::Round($selected.X * $script:Bounds.Width / 1920.0)
    $y = $Prompt.Y + [int][Math]::Round($selected.Y * $script:Bounds.Height / 1040.0)

    # The detected continue text is below the modal's central black strip.
    # Clamp every reward click to that lower confirmed zone.
    $minimumX = [int][Math]::Round(760.0 * $script:Bounds.Width / 1920.0)
    $maximumX = [int][Math]::Round(1160.0 * $script:Bounds.Width / 1920.0)
    $minimumY = [int][Math]::Round(850.0 * $script:Bounds.Height / 1040.0)
    $maximumY = [int][Math]::Round(985.0 * $script:Bounds.Height / 1040.0)
    return [System.Drawing.Point]::new(
        [Math]::Max($minimumX, [Math]::Min($maximumX, $x)),
        [Math]::Max($minimumY, [Math]::Min($maximumY, $y)))
}

function Complete-HKRewardDismissal {
    param([int]$Transition)
    Write-HKLog ("Reward closed at transition {0}/{1}; waiting 1220 ms before the next server action (700 ms state guard + 520 ms fixed pacing)." -f $Transition, $script:TargetTransition)
    if (-not (Wait-HKTechnicalDelay 700)) { return $false }
    return (Wait-HKFixedActionPacing "reward")
}

function Invoke-HKDismissReward {
    param(
        [int]$Transition,
        [switch]$CompletesTarget
    )

    $prompt = Wait-HKRewardPrompt ([int]$script:Settings.StateTimeoutSeconds)
    if ($script:StopRequested) { return $false }
    if ($prompt.X -lt 0) {
        return (Stop-HKOnUnexpectedState ("Ready reward prompt was not recognized at transition {0}/{1}." -f $Transition, $script:TargetTransition))
    }

    # The text can appear before its modal starts accepting input.  Give it a
    # short deterministic settle, then require three fresh confirming frames.
    if (-not (Wait-HKTechnicalDelay 220)) { return $false }
    $freshPrompt = Wait-HKRewardPrompt 2
    if ($script:StopRequested) { return $false }
    if ($freshPrompt.X -lt 0) {
        if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
        if ($script:StopRequested) { return $false }
        return (Stop-HKOnUnexpectedState ("Reward prompt became unclear before the guarded click at transition {0}/{1}; no blind click was made." -f $Transition, $script:TargetTransition))
    }

    $rewardPoint = Get-HKRewardClickPoint $freshPrompt 0
    if ($CompletesTarget) {
        Write-HKLog ("{0} exit click 1/3 (reward prompt below the centre strip) at {1},{2}." -f $script:TargetLabel, $rewardPoint.X, $rewardPoint.Y)
    } else {
        Write-HKLog ("Reward prompt click below the centre strip at {0},{1}." -f $rewardPoint.X, $rewardPoint.Y)
    }
    if (-not (Invoke-HKNudgedLocalClick $rewardPoint.X $rewardPoint.Y -StageOffsetX -12 -StageOffsetY -8 -StageDelayMilliseconds 100 -FinalDelayMilliseconds 140 -GuardKind "reward")) {
        if ($script:StopRequested) { return $false }
        if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
        if ($script:StopRequested) { return $false }

        # The animated prompt can briefly stop matching its visual checks
        # during the cursor nudge. Re-acquire the complete lower prompt from
        # fresh stable frames and permit one new guarded attempt. This is never
        # a blind retry: no mouse-down occurred in the cancelled attempt.
        $reacquiredPrompt = Wait-HKRewardPrompt 3
        if ($script:StopRequested) { return $false }
        if ($reacquiredPrompt.X -lt 0) {
            if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
            if ($script:StopRequested) { return $false }
            return (Stop-HKOnUnexpectedState ("Reward changed during the guarded cursor movement at transition {0}/{1} and could not be re-confirmed; no click was made." -f $Transition, $script:TargetTransition))
        }

        $reacquiredPoint = Get-HKRewardClickPoint $reacquiredPrompt 1
        Write-HKLog ("Reward prompt was re-confirmed after a cancelled cursor guard at transition {0}/{1}; one fresh guarded attempt at {2},{3}." -f $Transition, $script:TargetTransition, $reacquiredPoint.X, $reacquiredPoint.Y)
        if (-not (Invoke-HKNudgedLocalClick $reacquiredPoint.X $reacquiredPoint.Y -StageOffsetX 12 -StageOffsetY -8 -StageDelayMilliseconds 100 -FinalDelayMilliseconds 160 -GuardKind "reward")) {
            if ($script:StopRequested) { return $false }
            if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
            if ($script:StopRequested) { return $false }
            return (Stop-HKOnUnexpectedState ("Re-confirmed reward changed again during the guarded cursor movement at transition {0}/{1}; no click was made." -f $Transition, $script:TargetTransition))
        }
    }
    if (Wait-HKRewardAbsent 3) { return (Complete-HKRewardDismissal $Transition) }
    if ($script:StopRequested) { return $false }

    # One retry is permitted only while the full lower prompt is still stable.
    # It is again tied to the fresh prompt, never to the map or research panel.
    $retryPrompt = Wait-HKRewardPrompt 3
    if ($script:StopRequested) { return $false }
    if ($retryPrompt.X -lt 0) {
        if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
        if ($script:StopRequested) { return $false }
        return (Stop-HKOnUnexpectedState ("Reward entered an unclear state after the dismissal click at transition {0}/{1}; no blind retry was made." -f $Transition, $script:TargetTransition))
    }

    if (-not (Wait-HKTechnicalDelay 800)) { return $false }
    $freshRetryPrompt = Wait-HKRewardPrompt 2
    if ($script:StopRequested) { return $false }
    if ($freshRetryPrompt.X -lt 0) {
        if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
        if ($script:StopRequested) { return $false }
        return (Stop-HKOnUnexpectedState ("Reward retry lost its visual confirmation at transition {0}/{1}; no retry click was made." -f $Transition, $script:TargetTransition))
    }

    $retryPoint = Get-HKRewardClickPoint $freshRetryPrompt 1
    Write-HKLog ("Reward is still fully ready at transition {0}/{1}; one guarded nudged retry at {2},{3}." -f $Transition, $script:TargetTransition, $retryPoint.X, $retryPoint.Y)
    if (-not (Invoke-HKNudgedLocalClick $retryPoint.X $retryPoint.Y -StageOffsetX 12 -StageOffsetY -8 -StageDelayMilliseconds 100 -FinalDelayMilliseconds 160 -GuardKind "reward")) {
        if ($script:StopRequested) { return $false }
        if (Wait-HKRewardAbsent 2) { return (Complete-HKRewardDismissal $Transition) }
        if ($script:StopRequested) { return $false }
        return (Stop-HKOnUnexpectedState ("Reward changed during the retry cursor movement at transition {0}/{1}; no retry click was made." -f $Transition, $script:TargetTransition))
    }
    if (Wait-HKRewardAbsent 5) { return (Complete-HKRewardDismissal $Transition) }
    if ($script:StopRequested) { return $false }

    return (Stop-HKOnUnexpectedState ("Reward notification did not close after a ready-state click and one guarded retry at transition {0}/{1}." -f $Transition, $script:TargetTransition))
}

function Wait-HKFightAfterResearch {
    param([int]$Transition)

    # Normal game transitions observed so far complete within roughly four
    # seconds.  If Fight has not appeared after six seconds, classify the
    # screen before doing anything else.
    $fightButton = Wait-HKActionButton "fight" 6
    if ($script:StopRequested) { return [System.Drawing.Point]::new(-1, -1) }
    if ($fightButton.X -ge 0) { return $fightButton }

    $remainingResearch = Wait-HKActionButton "research" 3 3
    if ($script:StopRequested) { return [System.Drawing.Point]::new(-1, -1) }
    if ($remainingResearch.X -lt 0) {
        # The source screen is no longer stable; it may simply be a slower
        # transition.  Continue waiting only for the expected next state.
        return (Wait-HKActionButton "fight" ([int]$script:Settings.StateTimeoutSeconds))
    }

    Write-HKLog ("Research screen remained stable after the click at transition {0}/{1}; waiting 1200 ms before one guarded retry." -f $Transition, $script:TargetTransition)
    if (-not (Wait-HKTechnicalDelay 1200)) { return [System.Drawing.Point]::new(-1, -1) }

    $freshResearch = Wait-HKActionButton "research" 3 3
    if ($script:StopRequested) { return [System.Drawing.Point]::new(-1, -1) }
    if ($freshResearch.X -lt 0) {
        # State changed during the backoff, so a retry is forbidden.
        return (Wait-HKActionButton "fight" ([int]$script:Settings.StateTimeoutSeconds))
    }

    $retryPoint = [System.Drawing.Point]::new(
        $freshResearch.X,
        $freshResearch.Y + [int][Math]::Round(4.0 * $script:Bounds.Height / 1040.0))
    Write-HKLog ("Research request appears not to have been accepted; guarded retry at {0},{1}." -f $retryPoint.X, $retryPoint.Y)
    if (-not (Invoke-HKNudgedLocalClick $retryPoint.X $retryPoint.Y -StageOffsetX -10 -StageOffsetY -6 -StageDelayMilliseconds 100 -FinalDelayMilliseconds 140 -GuardKind "research")) {
        if ($script:StopRequested) { return [System.Drawing.Point]::new(-1, -1) }
        Write-HKLog "Research changed during the retry cursor movement; retry cancelled. Waiting only for Quick Fight."
        return (Wait-HKActionButton "fight" ([int]$script:Settings.StateTimeoutSeconds))
    }
    return (Wait-HKActionButton "fight" ([int]$script:Settings.StateTimeoutSeconds))
}

function Save-HKErrorSnapshot {
    param([string]$Prefix)
    try {
        $bitmap = Get-HKCapture
        $path = Join-Path $script:LogDirectory ("{0}_{1}.png" -f $Prefix, (Get-Date -Format "yyyyMMdd_HHmmss"))
        try { $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose() }
        Write-HKLog "Diagnostic screenshot saved: $path"
        return $path
    }
    catch {
        Write-HKLog ("Could not save diagnostic screenshot: " + $_.Exception.Message)
        return $null
    }
}

function Stop-HKOnUnexpectedState {
    param([string]$Message)
    if ($script:StopRequested) { return $false }
    Write-HKLog ("STOPPED SAFELY: " + $Message)
    [void](Save-HKErrorSnapshot "unexpected_state")
    [console]::Beep(420, 500)
    $script:StopRequested = $true
    return $false
}

function Save-HKMapTrace {
    param(
        [int]$BuildingNumber,
        [string]$Stage,
        [System.Drawing.Bitmap]$Bitmap = $null
    )
    if ($script:StopRequested) { return }
    $ownsBitmap = ($null -eq $Bitmap)
    try {
        if ($ownsBitmap) { $Bitmap = Get-HKCapture }
        $runName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFile)
        $fileName = "{0}_building_{1:D3}_{2}.png" -f $runName, $BuildingNumber, $Stage
        $path = Join-Path $script:LogDirectory $fileName
        $Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-HKLog ("Building #{0}: map {1} screenshot saved: {2}. Window origin: {3},{4}; size: {5}x{6}." -f $BuildingNumber, $Stage, $path, $script:Bounds.Left, $script:Bounds.Top, $Bitmap.Width, $Bitmap.Height)
        Remove-HKOldMapTraces -BuildingNumber $BuildingNumber
    }
    catch {
        Write-HKLog ("Could not save map trace for building #{0} ({1}): {2}" -f $BuildingNumber, $Stage, $_.Exception.Message)
    }
    finally {
        if ($ownsBitmap -and $null -ne $Bitmap) { $Bitmap.Dispose() }
    }
}

function Get-HKCurrentMarkers {
    param([switch]$SaveEmptySnapshot, [int]$BuildingNumber = 0)
    $bitmap = Get-HKCapture
    try {
        $markers = @([HKNative]::FindTierOneMarkers($bitmap))
        if ($BuildingNumber -gt 0 -and $markers.Count -gt 0) {
            # Save exactly the frame used to select the next marker, including
            # the first building and a successful rescan after an empty frame.
            Save-HKMapTrace -BuildingNumber $BuildingNumber -Stage "before_select" -Bitmap $bitmap
        }
        if ($SaveEmptySnapshot -and $markers.Count -eq 0) {
            # Preserve the actual frame that produced the final empty result.
            $path = Join-Path $script:LogDirectory ("no_markers_{0}.png" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
            try {
                $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
                Write-HKLog "Final empty map scan saved: $path"
            }
            catch {
                Write-HKLog ("Could not save empty map scan: " + $_.Exception.Message)
            }
        }
        return $markers
    }
    finally {
        $bitmap.Dispose()
    }
}

function Save-HKMarkerDiagnostic {
    $bitmap = Get-HKCapture
    try {
        $markers = @([HKNative]::FindTierOneMarkers($bitmap))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Magenta, 3)
            $font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
            $brush = [System.Drawing.Brushes]::Magenta
            try {
                $index = 1
                foreach ($marker in $markers) {
                    $graphics.DrawEllipse($pen, $marker.X - 13, $marker.Y - 13, 26, 26)
                    $graphics.DrawString([string]$index, $font, $brush, $marker.X + 14, $marker.Y - 16)
                    $index++
                }
            }
            finally {
                $pen.Dispose()
                $font.Dispose()
            }
        }
        finally {
            $graphics.Dispose()
        }

        $path = Join-Path $script:LogDirectory ("marker_check_{0}.png" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-HKLog ("Diagnostic found {0} Tier-1 marker(s)." -f $markers.Count)
        Write-HKLog ("Open this image and verify every magenta circle: " + $path)
        Start-Process $path
        return $markers.Count
    }
    finally {
        $bitmap.Dispose()
    }
}

function Invoke-HKProcessBuilding {
    param([System.Drawing.Point]$Marker, [int]$BuildingNumber)
    $script:LastBuildingTargetReached = $false
    Write-HKLog ("Building #{0}: selecting Tier-1 marker at {1},{2}." -f $BuildingNumber, $Marker.X, $Marker.Y)
    if (-not (Invoke-HKLocalClick $Marker.X $Marker.Y)) { return $false }
    if (-not (Wait-HKFixedActionPacing "marker")) { return $false }

    $buildingResearchButton = Wait-HKActionButton "building_research" ([int]$script:Settings.PanelTimeoutSeconds) 3
    if ($buildingResearchButton.X -lt 0) {
        Save-HKMapTrace -BuildingNumber $BuildingNumber -Stage "after_select"
        return (Stop-HKOnUnexpectedState "The white building-research HOME button was not found uniquely in the building header. No room action was clicked.")
    }
    Write-HKLog ("Building-research HOME button recognized at {0},{1}." -f $buildingResearchButton.X, $buildingResearchButton.Y)

    $safeMapPoints = Wait-HKStableSafeMapExitPoints 5 3
    # Capture the resulting map after the settling check, even if finding a
    # safe road failed. Do this before opening the research form.
    Save-HKMapTrace -BuildingNumber $BuildingNumber -Stage "after_select"
    if (-not $safeMapPoints.IsValid) {
        return (Stop-HKOnUnexpectedState "No stable, independently verified road points were found for the two exit clicks.")
    }
    Write-HKLog ("Safe map exit points: research {0},{1}; building {2},{3}. Both checked independently." -f $safeMapPoints.Research.X, $safeMapPoints.Research.Y, $safeMapPoints.Building.X, $safeMapPoints.Building.Y)
    if (-not (Invoke-HKLocalClick $buildingResearchButton.X $buildingResearchButton.Y)) { return $false }
    if (-not (Wait-HKFixedActionPacing "home")) { return $false }

    return (Invoke-HKUpgradeTransitions $safeMapPoints $BuildingNumber 1)
}

function Invoke-HKUpgradeTransitions {
    param(
        [HKMapExitPoints]$SafeMapPoints,
        [int]$BuildingNumber,
        [int]$StartTransition
    )

    if ($null -eq $SafeMapPoints -or -not $SafeMapPoints.IsValid) {
        return (Stop-HKOnUnexpectedState "Upgrade sequence has no verified map exit points.")
    }
    if ($StartTransition -gt $script:TargetTransition) {
        return (Stop-HKOnUnexpectedState ("Start transition {0} is above selected target transition {1}." -f $StartTransition, $script:TargetTransition))
    }

    for ($transition = $StartTransition; $transition -le $script:TargetTransition; $transition++) {
        Write-HKLog ("Building #{0}: upgrade transition {1}/{2}." -f $BuildingNumber, $transition, $script:TargetTransition)

        $researchButton = Wait-HKActionButton "research" ([int]$script:Settings.StateTimeoutSeconds) 3
        if ($script:StopRequested) { return $false }
        if ($researchButton.X -lt 0) {
            return (Stop-HKOnUnexpectedState ("Research screen was not recognized at transition {0}/{1}. The button may be inactive or resources may be insufficient." -f $transition, $script:TargetTransition))
        }
        if (-not (Invoke-HKNudgedLocalClick $researchButton.X $researchButton.Y -StageOffsetX -10 -StageOffsetY -6 -StageDelayMilliseconds 100 -FinalDelayMilliseconds 140)) { return $false }
        if (-not (Wait-HKFixedActionPacing "research")) { return $false }

        $fightButton = Wait-HKFightAfterResearch $transition
        if ($script:StopRequested) { return $false }
        if ($fightButton.X -lt 0) {
            return (Stop-HKOnUnexpectedState ("Quick Fight screen was not recognized at transition {0}/{1}, including after the single guarded Research retry." -f $transition, $script:TargetTransition))
        }
        if (-not (Invoke-HKLocalClick $fightButton.X $fightButton.Y)) { return $false }
        if (-not (Wait-HKFixedActionPacing "fight")) { return $false }

        $renovationButton = Wait-HKActionButton "renovation" ([int]$script:Settings.FightTimeoutSeconds)
        if ($renovationButton.X -lt 0) {
            return (Stop-HKOnUnexpectedState ("Renovation screen was not recognized after Quick Fight at transition {0}/{1}." -f $transition, $script:TargetTransition))
        }
        if (-not (Invoke-HKLocalClick $renovationButton.X $renovationButton.Y)) { return $false }
        if (-not (Wait-HKFixedActionPacing "renovation")) { return $false }

        if ($transition -eq $script:TargetTransition) {
            if (-not (Invoke-HKDismissReward $transition -CompletesTarget)) { return $false }
        } else {
            if (-not (Invoke-HKDismissReward $transition)) { return $false }
        }

    }

    Write-HKLog ("Building #{0}: transitions {1}..{2} completed; target {3} reached." -f $BuildingNumber, $StartTransition, $script:TargetTransition, $script:TargetLabel)
    $finalResearchScreen = Wait-HKActionButton "research" ([int]$script:Settings.StateTimeoutSeconds) 3
    if ($finalResearchScreen.X -lt 0) {
        return (Stop-HKOnUnexpectedState ("Final research screen for {0} was not recognized after transition {1}/{1}." -f $script:TargetLabel, $script:TargetTransition))
    }
    $script:LastBuildingTargetReached = $true
    Write-HKLog ("Final {0} research screen recognized. Selected target is complete; no higher-tier or MAX click will be made." -f $script:TargetLabel)

    # The lower prompt click already dismissed the selected target's reward.
    # Two separate map clicks close the research form and then the selected
    # building panel, matching the verified in-game behaviour.
    $researchClosePoint = $SafeMapPoints.Research
    Write-HKLog ("{0} exit click 2/3 (research form) at {1},{2}." -f $script:TargetLabel, $researchClosePoint.X, $researchClosePoint.Y)
    if (-not (Invoke-HKLocalClick $researchClosePoint.X $researchClosePoint.Y)) { return $false }
    if (-not (Wait-HKFixedActionPacing "close_research")) { return $false }
    if (-not (Wait-HKActionAbsent "research" 8)) {
        return (Stop-HKOnUnexpectedState ("{0} research form did not close after the second map click." -f $script:TargetLabel))
    }

    $buildingClosePoint = $SafeMapPoints.Building
    Write-HKLog ("{0} exit click 3/3 (building panel) at {1},{2}." -f $script:TargetLabel, $buildingClosePoint.X, $buildingClosePoint.Y)
    if (-not (Invoke-HKLocalClick $buildingClosePoint.X $buildingClosePoint.Y)) { return $false }
    if (-not (Wait-HKFixedActionPacing "close_building")) { return $false }
    if (-not (Wait-HKActionAbsent "building_research" 10)) {
        return (Stop-HKOnUnexpectedState "Selected-building panel did not close after the third map click.")
    }
    Write-HKLog ("{0} reward, research form and selected-building panel are closed. Map is ready." -f $script:TargetLabel)
    return $true
}

function Invoke-HKResumeTier2 {
    $script:LastBuildingTargetReached = $false
    Write-HKLog "Tier-2 recovery: checking the current reward/research screen."

    # The reported interrupted run stopped after transition 1/6.  If its
    # ready reward is still open, close it through the detected continue text.
    # If the user has already closed only that reward, the Tier-2 research
    # screen is accepted directly below.
    $prompt = Wait-HKRewardPrompt 2
    if ($prompt.X -ge 0) {
        Write-HKLog ("Tier-2 recovery: ready reward prompt recognized at {0},{1}." -f $prompt.X, $prompt.Y)
        if (-not (Invoke-HKDismissReward 1)) { return $false }
    }

    $researchScreen = Wait-HKActionButton "research" ([int]$script:Settings.StateTimeoutSeconds) 3
    if ($researchScreen.X -lt 0) {
        return (Stop-HKOnUnexpectedState "Tier-2 recovery expected the current research screen, but it was not recognized. No research action was clicked.")
    }

    $tierBitmap = Get-HKCapture
    try {
        $tierTwoConfirmed = [HKNative]::IsTierTwoActive($tierBitmap)
    }
    finally {
        $tierBitmap.Dispose()
    }
    if (-not $tierTwoConfirmed) {
        return (Stop-HKOnUnexpectedState "Tier-2 recovery did not positively confirm the active Tier-2 indicator. No research action was clicked.")
    }
    Write-HKLog "Tier-2 recovery: active Tier-2 indicator confirmed visually."

    $safeMapPoints = Wait-HKStableSafeMapExitPoints 5 3
    if (-not $safeMapPoints.IsValid) {
        return (Stop-HKOnUnexpectedState "Tier-2 recovery could not find stable, independently verified road points for the two exit clicks.")
    }
    Write-HKLog ("Tier-2 recovery: safe map exit points: research {0},{1}; building {2},{3}; continuing with transition 2/{4}." -f $safeMapPoints.Research.X, $safeMapPoints.Research.Y, $safeMapPoints.Building.X, $safeMapPoints.Building.Y, $script:TargetTransition)
    return (Invoke-HKUpgradeTransitions $safeMapPoints 1 2)
}

function Show-HKMenu {
    Write-Host ""
    Write-Host "Hamster King Tier Autopilot"
    Write-Host "1 - One building, then stop (recommended first live test)"
    Write-Host "2 - Up to five visible buildings"
    Write-Host "3 - All currently visible Tier-1 markers"
    Write-Host "4 - Marker check only; no clicks"
    Write-Host ""
    $choice = Read-Host "Choose 1, 2, 3 or 4"
    switch ($choice) {
        "2" { return "five" }
        "3" { return "all" }
        "4" { return "check" }
        default { return "one" }
    }
}

try {
    $script:SessionLock = [System.IO.File]::Open(
        (Join-Path $script:LogDirectory "session.lock"),
        [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
    Write-HKLog "Starting Hamster King Tier Autopilot v1.20."
    Remove-HKOldSessionDiagnostics
    Write-HKLog "Diagnostics: keeping the latest 5 sessions and 5 building screenshot pairs per session, plus the latest failed session."
    if (-not (Update-HKGeometry)) { exit 0 }
    Write-HKLog ("Game window found: {0}x{1}." -f $script:Bounds.Width, $script:Bounds.Height)

    if ($script:WaitedForGameTab -and $Mode -ne "check") {
        Restore-HKConsole
        Write-HKLog "Control window restored after the game tab was detected."
    }

    if ($Mode -eq "menu") { $Mode = Show-HKMenu }
    if ($Mode -eq "check") {
        Set-HKForeground
        Start-Sleep -Milliseconds 800
        [void](Save-HKMarkerDiagnostic)
        Write-HKLog "Diagnostic finished. No game clicks were made."
        $script:SilentConsoleExit = $true
        exit 0
    }

    $maximumBuildings = 1
    if ($Mode -eq "five") { $maximumBuildings = 5 }
    if ($Mode -eq "all") { $maximumBuildings = [int]$script:Settings.MaxBuildingsPerRun }

    Write-Host ""
    if ($Mode -eq "resume2") {
        Write-Host "RECOVERY MODE: use only for the current building interrupted after reaching Tier 2."
        Write-Host "Leave either its reward prompt or its Tier-2 research screen open."
    } else {
        Write-Host ("Prepare the map: Tier-1 building filter enabled, no dialog open. Target: {0}." -f $script:TargetLabel)
    }
    Write-Host "Press F8 to START/PAUSE. Press F9 for EMERGENCY STOP."
    Write-Host "Do not move the mouse or switch windows while running."
    Write-Host ""
    Write-HKLog ("Selected mode: {0}. Target: {1}. Waiting for F8." -f $Mode, $script:TargetLabel)

    if (-not (Wait-HKReady)) { exit 0 }

    $completed = 0
    if ($Mode -eq "resume2") {
        $mapReady = Invoke-HKResumeTier2
        if ($script:LastBuildingTargetReached) { $completed++ }
    } else {
        while (-not $script:StopRequested -and $completed -lt $maximumBuildings) {
            # The game recentres the map after a building is selected. Never reuse
            # screen coordinates from a previous building: take a fresh screenshot
            # and locate the currently visible filtered markers again.
            $markers = @(Get-HKCurrentMarkers -BuildingNumber ($completed + 1))
            # Pins may appear after the panels have closed and the map settles.
            # Retry only empty scans; never click using a previous map frame.
            for ($emptyScanRetry = 1; $markers.Count -eq 0 -and $emptyScanRetry -le 3; $emptyScanRetry++) {
                Write-HKLog ("No markers in this frame; waiting for fresh map scan {0}/4." -f ($emptyScanRetry + 1))
                if (-not (Wait-HKTechnicalDelay -Milliseconds 400)) { break }
                $markers = @(Get-HKCurrentMarkers -SaveEmptySnapshot:($emptyScanRetry -eq 3) -BuildingNumber ($completed + 1))
            }
            if ($script:StopRequested) { break }
            if ($markers.Count -eq 0) {
                Write-HKLog "No Tier-1 markers detected in four fresh scans of the visible map. Finished."
                break
            }

            Write-HKLog ("Fresh map scan found {0} current Tier-1 marker(s)." -f $markers.Count)
            $marker = $markers[0]
            $mapReady = Invoke-HKProcessBuilding $marker ($completed + 1)
            if ($script:LastBuildingTargetReached) { $completed++ }
            if (-not $mapReady) { break }
        }
    }

    if ($script:StopRequested) {
        Write-HKLog ("Run stopped. Buildings completed in this run: {0}." -f $completed)
    } else {
        Write-HKLog ("Run complete. Buildings completed in this run: {0}." -f $completed)
        [console]::Beep(950, 180)
        [console]::Beep(1150, 250)
    }
}
catch {
    $script:ExitCode = 1
    Write-HKLog ("FATAL ERROR: " + $_.Exception.Message)
    [void](Save-HKErrorSnapshot "fatal_error")
    [console]::Beep(380, 600)
}
finally {
    if ($null -ne $script:SessionLock) { $script:SessionLock.Dispose() }
    if (-not $script:SilentConsoleExit) {
        Restore-HKConsole
        Write-Host ""
        Read-Host "Press Enter to close"
    }
}

exit $script:ExitCode
