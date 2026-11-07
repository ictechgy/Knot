// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    // This entrypoint owns every control and bitmap it examines. It deliberately
    // invokes the production opaque OnPaint path without a preceding WM_PRINT
    // background pass, which can conceal uninitialised rounded-corner pixels in
    // a whole-form DrawToBitmap. No desktop pixels, input or user state is read.
    internal static class PreviewButtonPaintChecks
    {
        private static readonly MethodInfo Paint = typeof(PreviewButton).GetMethod("OnPaint", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly MethodInfo Surface = typeof(PreviewButton).GetMethod("DrawSurface", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly MethodInfo Enter = typeof(PreviewButton).GetMethod("OnMouseEnter", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly MethodInfo Leave = typeof(PreviewButton).GetMethod("OnMouseLeave", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly MethodInfo Style = typeof(Control).GetMethod("GetStyle", BindingFlags.Instance | BindingFlags.NonPublic);
        private static readonly Color Poison = Color.FromArgb(17, 13, 17, 23);

        internal static string Run()
        {
            if (Paint == null || Enter == null || Leave == null || Style == null)
                throw new InvalidOperationException("The actual button paint entrypoints are unavailable.");
            int[] dpis = { 96, 120, 144, 192, 288 };
            Size[] logicalSizes = { new Size(120, 44), new Size(84, 32) };
            Color[] backdrops = { PreviewStyle.Canvas, PreviewStyle.Rail, PreviewStyle.Surface };
            PreviewButtonKind[] kinds = { PreviewButtonKind.Primary, PreviewButtonKind.Secondary, PreviewButtonKind.Danger, PreviewButtonKind.Navigation };
            int rasters = 0, partials = 0, repaints = 0;
            bool? opaque = null;
            foreach (int dpi in dpis)
                foreach (Size logical in logicalSizes)
                    foreach (Color backdrop in backdrops)
                        foreach (PreviewButtonKind kind in kinds)
                            for (int selection = 0; selection < (kind == PreviewButtonKind.Navigation ? 2 : 1); ++selection)
                                for (int enabled = 0; enabled < 2; ++enabled)
                                    for (int hover = 0; hover < 2; ++hover)
                                    {
                                        Size pixels = Scale(logical, dpi);
                                        using (Panel parent = new Panel())
                                        using (Panel transparent = new Panel())
                                        using (PreviewButton button = NewButton(kind, pixels))
                                        using (Bitmap bitmap = NewBitmap(pixels, dpi))
                                        {
                                            parent.BackColor = backdrop; parent.Size = pixels;
                                            transparent.BackColor = Color.Transparent; transparent.Size = pixels;
                                            parent.Controls.Add(transparent); transparent.Controls.Add(button);
                                            button.Selected = selection != 0; button.Enabled = enabled != 0;
                                            (hover != 0 ? Enter : Leave).Invoke(button, new object[] { EventArgs.Empty });
                                            bool actualOpaque = (bool)Style.Invoke(button, new object[] { ControlStyles.Opaque });
                                            if (opaque.HasValue && opaque.Value != actualOpaque)
                                                throw new InvalidOperationException("The button paint ownership changed between inert cases.");
                                            opaque = actualOpaque;
                                            using (Graphics graphics = Graphics.FromImage(bitmap))
                                            {
                                                if (Math.Abs(graphics.DpiX - dpi) > 0.01 || Math.Abs(graphics.DpiY - dpi) > 0.01)
                                                    throw new InvalidOperationException("The bitmap did not retain the actual requested drawing DPI.");
                                                graphics.Clear(Poison);
                                                Draw(button, graphics, button.ClientRectangle);
                                            }
                                            string context = "fresh " + kind + " dpi=" + dpi + " size=" + pixels +
                                                " selected=" + (selection != 0) + " enabled=" + (enabled != 0) +
                                                " hovered=" + (hover != 0) + " inheritedOpaque=" + actualOpaque;
                                            AssertOpaque(bitmap, context);
                                            AssertCorners(bitmap, backdrop, context);
                                            AssertPixel(bitmap, pixels.Width / 2, pixels.Height / 2,
                                                ExpectedFace(kind, selection != 0, enabled != 0, hover != 0), "button face");
                                            ++rasters;
                                        }
                                    }

            foreach (int dpi in dpis)
                foreach (PreviewButtonKind kind in kinds)
                {
                    CheckRepaintAndResize(kind, dpi); ++repaints;
                    CheckPartialClip(kind, dpi); ++partials;
                }
            return "{\"status\":\"PASS\",\"rasterCases\":" + rasters + ",\"repaintCases\":" + repaints +
                ",\"partialClipCases\":" + partials + ",\"minimumDpi\":96,\"maximumDpi\":288," +
                "\"buttonKinds\":4,\"opaqueCorners\":true,\"parentBackdrop\":true,\"transparentAncestors\":true," +
                "\"partialClipPreserved\":true,\"actualGraphicsDpi\":true,\"allPixelsInitialized\":true," +
                "\"inheritedOpaqueObserved\":" + (opaque == true ? "true" : "false") + ",\"freshSyntheticOnly\":true," +
                "\"productionEntryInvoked\":false,\"actualInputInvoked\":false,\"screenCaptureInvoked\":false," +
                "\"scope\":\"Production opaque button paint on owned poisoned bitmaps; not physical DWM or per-monitor acceptance\"}";
        }

        private static Size Scale(Size logical, int dpi)
        { return new Size((int)Math.Round(logical.Width * dpi / 96.0), (int)Math.Round(logical.Height * dpi / 96.0)); }

        private static PreviewButton NewButton(PreviewButtonKind kind, Size pixels)
        {
            PreviewButton button = new PreviewButton("", kind, 1f);
            button.AutoSize = false; button.MinimumSize = Size.Empty; button.Size = pixels;
            return button;
        }

        private static Bitmap NewBitmap(Size pixels, int dpi)
        {
            Bitmap bitmap = new Bitmap(pixels.Width, pixels.Height, PixelFormat.Format32bppArgb);
            bitmap.SetResolution(dpi, dpi); return bitmap;
        }

        private static void Draw(PreviewButton button, Graphics graphics, Rectangle clip)
        {
            if (Surface != null) Surface.Invoke(button, new object[] { graphics });
            else
            {
                // Keep the regression compilable against the old style source
                // for a fail-before witness. The legacy opaque painter must
                // fail the same independent corner/alpha oracle.
                Paint.Invoke(button, new object[] { new PaintEventArgs(graphics, clip) });
            }
        }

        private static Color ExpectedFace(PreviewButtonKind kind, bool selected, bool enabled, bool hovered)
        {
            if (!enabled) return PreviewStyle.Rail;
            if (hovered && kind != PreviewButtonKind.Primary) return PreviewStyle.AccentWash;
            if (kind == PreviewButtonKind.Primary) return PreviewStyle.Accent;
            if (kind == PreviewButtonKind.Navigation) return selected ? PreviewStyle.AccentWash : PreviewStyle.Rail;
            return PreviewStyle.Surface;
        }

        private static void CheckRepaintAndResize(PreviewButtonKind kind, int dpi)
        {
            using (Panel parent = new Panel())
            using (Panel transparent = new Panel())
            using (PreviewButton button = NewButton(kind, Scale(new Size(120, 44), dpi)))
            {
                parent.BackColor = Color.FromArgb(31, 71, 103);
                transparent.BackColor = Color.Transparent;
                parent.Controls.Add(transparent); transparent.Controls.Add(button);
                foreach (Size logical in new Size[] { new Size(120, 44), new Size(84, 32), new Size(156, 52) })
                {
                    button.Size = Scale(logical, dpi); parent.Size = button.Size; transparent.Size = button.Size;
                    using (Bitmap bitmap = NewBitmap(button.Size, dpi))
                    {
                        using (Graphics graphics = Graphics.FromImage(bitmap))
                        { graphics.Clear(Poison); Draw(button, graphics, button.ClientRectangle); }
                        Color changed = Color.FromArgb(97, 131, 149);
                        parent.BackColor = changed;
                        button.Selected = true; Enter.Invoke(button, new object[] { EventArgs.Empty });
                        using (Graphics graphics = Graphics.FromImage(bitmap)) Draw(button, graphics, button.ClientRectangle);
                        AssertOpaque(bitmap, "parent change/resize " + kind + " dpi=" + dpi);
                        AssertCorners(bitmap, changed, "parent change/resize " + kind + " dpi=" + dpi);
                        parent.BackColor = Color.FromArgb(31, 71, 103);
                        button.Enabled = false; Leave.Invoke(button, new object[] { EventArgs.Empty });
                        using (Graphics graphics = Graphics.FromImage(bitmap)) Draw(button, graphics, button.ClientRectangle);
                        AssertOpaque(bitmap, "disabled repaint " + kind + " dpi=" + dpi);
                        AssertCorners(bitmap, parent.BackColor, "disabled repaint " + kind + " dpi=" + dpi);
                        button.Enabled = true;
                    }
                }
            }
        }

        private static void CheckPartialClip(PreviewButtonKind kind, int dpi)
        {
            using (Panel parent = new Panel())
            using (Panel transparent = new Panel())
            using (PreviewButton button = NewButton(kind, Scale(new Size(120, 44), dpi)))
            using (Bitmap bitmap = NewBitmap(button.Size, dpi))
            {
                parent.BackColor = Color.FromArgb(31, 71, 103); parent.Size = button.Size;
                transparent.BackColor = Color.Transparent; transparent.Size = button.Size;
                parent.Controls.Add(transparent); transparent.Controls.Add(button);
                using (Graphics graphics = Graphics.FromImage(bitmap))
                { graphics.Clear(Poison); Draw(button, graphics, button.ClientRectangle); }
                byte[] before = Pixels(bitmap);
                Color changed = Color.FromArgb(97, 131, 149); parent.BackColor = changed;
                Rectangle clip = new Rectangle(0, 0, button.Width / 2, button.Height / 2);
                using (Graphics graphics = Graphics.FromImage(bitmap))
                {
                    GraphicsState state = graphics.Save();
                    try { graphics.SetClip(clip); Draw(button, graphics, clip); }
                    finally { graphics.Restore(state); }
                }
                byte[] after = Pixels(bitmap);
                for (int y = 0; y < bitmap.Height; ++y)
                    for (int x = 0; x < bitmap.Width; ++x)
                        if (!clip.Contains(x, y))
                        {
                            int offset = (y * bitmap.Width + x) * 4;
                            for (int channel = 0; channel < 4; ++channel)
                                if (before[offset + channel] != after[offset + channel])
                                    throw new InvalidOperationException("A partial button paint changed pixels outside its clip: " + kind + " dpi=" + dpi);
                        }
                AssertOpaque(bitmap, "partial clip " + kind + " dpi=" + dpi);
                AssertPixel(bitmap, 0, 0, changed, "clipped backdrop corner");
                AssertPixel(bitmap, bitmap.Width - 1, bitmap.Height - 1, Color.FromArgb(31, 71, 103), "unpainted clip exterior");
            }
        }

        private static byte[] Pixels(Bitmap bitmap)
        {
            BitmapData data = bitmap.LockBits(new Rectangle(Point.Empty, bitmap.Size), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                if (data.Stride != bitmap.Width * 4) throw new InvalidOperationException("Unexpected owned button bitmap row layout.");
                byte[] pixels = new byte[data.Stride * data.Height]; Marshal.Copy(data.Scan0, pixels, 0, pixels.Length); return pixels;
            }
            finally { bitmap.UnlockBits(data); }
        }

        private static void AssertOpaque(Bitmap bitmap, string context)
        {
            byte[] pixels = Pixels(bitmap);
            for (int i = 3; i < pixels.Length; i += 4)
                if (pixels[i] != 255)
                    throw new InvalidOperationException("Opaque button painting left an uninitialised or translucent client pixel: " +
                        context + " pixel=" + ((i / 4) % bitmap.Width) + "," + ((i / 4) / bitmap.Width) + " alpha=" + pixels[i] + ".");
        }

        private static void AssertCorners(Bitmap bitmap, Color expected, string context)
        {
            AssertPixel(bitmap, 0, 0, expected, context);
            AssertPixel(bitmap, bitmap.Width - 1, 0, expected, context);
            AssertPixel(bitmap, 0, bitmap.Height - 1, expected, context);
            AssertPixel(bitmap, bitmap.Width - 1, bitmap.Height - 1, expected, context);
        }

        private static void AssertPixel(Bitmap bitmap, int x, int y, Color expected, string context)
        {
            Color actual = bitmap.GetPixel(x, y);
            if (actual.ToArgb() != expected.ToArgb())
                throw new InvalidOperationException("Incorrect button pixel (" + x + "," + y + ") " + context + ": expected " + expected.ToArgb() + ", observed " + actual.ToArgb() + ".");
        }
    }
}
