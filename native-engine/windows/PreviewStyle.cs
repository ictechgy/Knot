// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Knot.NativePreview
{
    // Paint the actual packaged icon through GDI+ instead of converting its
    // PNG-compressed ICO frame to a PictureBox bitmap. Used by production too.
    internal sealed class KnotBrandMark : Control
    {
        private readonly Icon icon;
        internal int DrawCalls { get; private set; }
        internal KnotBrandMark(Icon source)
        {
            icon = source == null ? null : (Icon)source.Clone();
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; TabStop = false;
            AccessibleRole = AccessibleRole.Graphic; AccessibleName = "Knot 로고";
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (icon == null || Width < 1 || Height < 1) return;
            int edge = Math.Min(Width, Height);
            e.Graphics.DrawIcon(icon, new Rectangle((Width - edge) / 2, (Height - edge) / 2, edge, edge));
            ++DrawCalls;
        }
        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing && icon != null) icon.Dispose();
        }
    }

    internal static class PreviewStyle
    {
        internal static Color Canvas { get { return SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(246, 247, 249); } }
        internal static Color Rail { get { return SystemInformation.HighContrast ? SystemColors.Control : Color.FromArgb(238, 241, 245); } }
        internal static Color Surface { get { return SystemColors.Window; } }
        internal static Color Ink { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(31, 41, 55); } }
        internal static Color Muted { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(100, 112, 130); } }
        internal static Color Border { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(221, 226, 234); } }
        internal static Color Accent { get { return SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(37, 99, 235); } }
        internal static Color AccentWash { get { return SystemInformation.HighContrast ? SystemColors.Control : Color.FromArgb(226, 235, 253); } }
        internal static Color Danger { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(173, 45, 55); } }
        internal static Color Warning { get { return SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(133, 88, 27); } }
        internal static Font Type(float size, FontStyle weight, float scale) { return new Font("Segoe UI", size * scale, weight, GraphicsUnit.Point); }
        internal static GraphicsPath Rounded(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int d = Math.Min(radius * 2, Math.Min(bounds.Width, bounds.Height));
            if (d < 2) { path.AddRectangle(bounds); return path; }
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure(); return path;
        }
    }

    // The trust block has a known two-child geometry. Do not ask nested
    // AutoSize/percent tables to discover the native edit control's height.
    internal sealed class PreviewTrustPanel : Panel
    {
        private readonly Label title;
        private readonly TextBox pin;
        private bool arranging;
        private int gap, minimumPinHeight, pinPadding;
        internal PreviewTrustPanel(Label heading, TextBox fingerprint)
        {
            title = heading; pin = fingerprint;
            AutoSize = false; BackColor = PreviewStyle.Surface;
            title.AutoSize = false; title.Dock = pin.Dock = DockStyle.None;
            pin.AutoSize = false; title.Anchor = pin.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            title.MaximumSize = Size.Empty;
            Controls.Add(title); Controls.Add(pin);
            AccessibleRole = AccessibleRole.Grouping;
            AccessibleName = "현재 연결의 인증서 지문";
        }
        internal void SetMetrics(int titleGap, int minimumHeight, int padding)
        {
            gap = titleGap; minimumPinHeight = minimumHeight; pinPadding = padding;
            PerformLayout();
        }
        internal int RequiredPinHeight
        {
            get
            {
                int width = Math.Max(1, ClientSize.Width - pinPadding);
                int textWidth = TextRenderer.MeasureText(pin.Text.Length == 0 ? "0" : pin.Text, pin.Font, Size.Empty,
                    TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Width;
                int lines = Math.Max(1, (textWidth + width - 1) / width);
                int lineHeight = TextRenderer.MeasureText("Ag", pin.Font, Size.Empty, TextFormatFlags.SingleLine | TextFormatFlags.NoPadding).Height;
                return Math.Max(minimumPinHeight, lines * lineHeight + pinPadding);
            }
        }
        public override Size GetPreferredSize(Size proposedSize)
        {
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : Width, Height);
        }
        protected override void OnLayout(LayoutEventArgs e)
        {
            if (arranging) return;
            if (title == null || pin == null || !Visible || ClientSize.Width <= pinPadding) { base.OnLayout(e); return; }
            arranging = true;
            try
            {
                base.OnLayout(e);
                int width = Math.Max(1, ClientSize.Width);
                int titleHeight = TextRenderer.MeasureText(title.Text, title.Font, new Size(width, 32767),
                    TextFormatFlags.WordBreak | TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix).Height;
                title.SetBounds(0, 0, width, titleHeight);
                int pinHeight = RequiredPinHeight;
                pin.SetBounds(0, titleHeight + gap, width, pinHeight);
                int height = titleHeight + gap + pinHeight;
                if (Height != height) Height = height;
            }
            finally { arranging = false; }
        }
    }

    internal sealed class PreviewCard : Panel
    {
        private readonly float layoutScale;
        internal readonly TableLayoutPanel Content = new TableLayoutPanel();
        internal PreviewCard(float scale)
        {
            layoutScale = scale;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Padding = new Padding((int)Math.Round(24 * scale));
            Margin = new Padding(0, 0, 0, (int)Math.Round(16 * scale));
            Content.ColumnCount = 1; Content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            Content.Dock = DockStyle.Top; Content.AutoSize = true; Content.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Content.BackColor = PreviewStyle.Surface; Content.Margin = Padding.Empty;
            Controls.Add(Content); AccessibleRole = AccessibleRole.Grouping;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rectangle = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            using (GraphicsPath path = PreviewStyle.Rounded(rectangle, (int)Math.Round(10 * layoutScale * e.Graphics.DpiX / 96)))
            using (Brush fill = new SolidBrush(PreviewStyle.Surface))
            using (Pen border = new Pen(PreviewStyle.Border))
            { e.Graphics.FillPath(fill, path); e.Graphics.DrawPath(border, path); }
            base.OnPaint(e);
        }
    }

    internal enum PreviewButtonKind { Primary, Secondary, Danger, Navigation }
    internal sealed class PreviewButton : Button
    {
        internal PreviewButtonKind Kind;
        internal bool Selected;
        private bool hovered;
        private readonly float layoutScale;
        internal PreviewButton(string text, PreviewButtonKind kind, float scale)
        {
            layoutScale = scale;
            Text = text; Kind = kind; UseMnemonic = false; AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink; FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0; Cursor = Cursors.Hand;
            // The form assigns and tracks the freshly allocated font so equal
            // values never cause disposal of a font still used by this button.
            Padding = new Padding((int)(18 * scale), (int)(10 * scale), (int)(18 * scale), (int)(10 * scale));
            MinimumSize = new Size(0, (int)(44 * scale));
            Margin = new Padding(0, 0, (int)(10 * scale), 0);
            BackColor = PreviewStyle.Surface; ForeColor = PreviewStyle.Ink;
            AccessibleName = text;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }
        protected override void OnMouseEnter(EventArgs e) { hovered = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovered = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            DrawSurface(e.Graphics);
        }
        // ButtonBase is opaque: WM_PAINT can skip OnPaintBackground. Own the
        // complete client surface, including the pixels outside rounded corners.
        // Knot's solid panels may be separated by transparent layout wrappers.
        internal void DrawSurface(Graphics graphics)
        {
            Color backdrop = PreviewStyle.Canvas;
            for (Control ancestor = Parent; ancestor != null; ancestor = ancestor.Parent)
                if (ancestor.BackColor.A == 255) { backdrop = ancestor.BackColor; break; }
            // FillRectangle preserves a partial invalidation clip; Clear does not.
            using (Brush canvas = new SolidBrush(backdrop)) graphics.FillRectangle(canvas, ClientRectangle);
            Color background = Kind == PreviewButtonKind.Primary ? PreviewStyle.Accent : PreviewStyle.Surface;
            Color foreground = Kind == PreviewButtonKind.Primary ? SystemColors.HighlightText : Kind == PreviewButtonKind.Danger ? PreviewStyle.Danger : PreviewStyle.Ink;
            if (Kind == PreviewButtonKind.Navigation) { background = Selected ? PreviewStyle.AccentWash : PreviewStyle.Rail; foreground = Selected ? PreviewStyle.Accent : PreviewStyle.Muted; }
            if (!Enabled) { background = PreviewStyle.Rail; foreground = SystemColors.GrayText; }
            else if (hovered && Kind != PreviewButtonKind.Primary) background = PreviewStyle.AccentWash;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle rectangle = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            using (GraphicsPath path = PreviewStyle.Rounded(rectangle, (int)Math.Round(8 * layoutScale * graphics.DpiX / 96)))
            using (Brush fill = new SolidBrush(background))
            { graphics.FillPath(fill, path); if (Kind == PreviewButtonKind.Secondary || Kind == PreviewButtonKind.Danger) using (Pen pen = new Pen(PreviewStyle.Border)) graphics.DrawPath(pen, path); }
            TextRenderer.DrawText(graphics, Text, Font, ClientRectangle, foreground,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(graphics, Rectangle.Inflate(ClientRectangle, -4, -4), foreground, background);
        }
    }

    internal sealed class MonitorIllustration : Control
    {
        internal MonitorIllustration()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            AccessibleRole = AccessibleRole.Graphic; AccessibleName = "Windows PC 화면 공유";
            TabStop = false;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            DrawIllustration(e.Graphics);
            base.OnPaint(e);
        }

        protected override void OnDpiChangedAfterParent(EventArgs e)
        {
            base.OnDpiChangedAfterParent(e);
            Invalidate();
        }

        // The synthetic fixture paints this same production path into fresh
        // bitmaps at several DPIs, without creating a host or reading a screen.
        internal void DrawIllustration(Graphics graphics)
        {
            MonitorGeometry geometry;
            if (!MonitorGeometry.TryFit(ClientSize, out geometry)) return;
            GraphicsState saved = graphics.Save();
            try
            {
                graphics.PageUnit = GraphicsUnit.Pixel;
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                float stroke = Math.Max(0.75f, 2 * geometry.Unit);
                using (GraphicsPath path = PreviewStyle.Rounded(Rectangle.Round(geometry.Screen), Math.Max(1, (int)Math.Round(7 * geometry.Unit))))
                using (Brush fill = new SolidBrush(PreviewStyle.AccentWash))
                using (Pen border = new Pen(PreviewStyle.Accent, stroke))
                { graphics.FillPath(fill, path); graphics.DrawPath(border, path); }
                using (Pen pen = new Pen(PreviewStyle.Accent, stroke))
                {
                    graphics.DrawLine(pen, geometry.StemTop, geometry.StemBottom);
                    graphics.DrawLine(pen, geometry.BaseLeft, geometry.BaseRight);
                }
                RectangleF interior = geometry.Screen;
                interior.Inflate(-stroke, -stroke);
                graphics.SetClip(interior, CombineMode.Intersect);
                using (Brush pane = new SolidBrush(PreviewStyle.Accent))
                    for (int row = 0; row < 2; ++row)
                        for (int column = 0; column < 2; ++column)
                            graphics.FillRectangle(pane, geometry.Pane(column, row));
            }
            finally { graphics.Restore(saved); }
        }
    }
}
