// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Drawing;

namespace Knot.NativePreview
{
    // Every part shares one fitted design space. Client pixels already reflect
    // WinForms layout/DPI; a second Graphics.Dpi multiplier would distort it.
    internal struct MonitorGeometry
    {
        internal readonly RectangleF Screen, Logo;
        internal readonly PointF StemTop, StemBottom, BaseLeft, BaseRight;
        internal readonly float Unit;

        private MonitorGeometry(float x, float y, float unit)
        {
            Unit = unit;
            Screen = new RectangleF(x + 8 * unit, y + 4 * unit, 118 * unit, 72 * unit);
            float centerX = Screen.Left + Screen.Width / 2, centerY = Screen.Top + Screen.Height / 2;
            Logo = new RectangleF(centerX - 19 * unit, centerY - 19 * unit, 38 * unit, 38 * unit);
            StemTop = new PointF(centerX, Screen.Bottom);
            StemBottom = new PointF(centerX, Screen.Bottom + 12 * unit);
            BaseLeft = new PointF(centerX - 18 * unit, StemBottom.Y);
            BaseRight = new PointF(centerX + 18 * unit, StemBottom.Y);
        }

        internal static bool TryFit(Size client, out MonitorGeometry geometry)
        {
            geometry = default(MonitorGeometry);
            if (client.Width < 16 || client.Height < 12) return false;
            float unit = Math.Min(client.Width / 134f, client.Height / 92f);
            geometry = new MonitorGeometry((client.Width - 134 * unit) / 2,
                (client.Height - 92 * unit) / 2, unit);
            return true;
        }

        internal RectangleF Pane(int column, int row)
        {
            if (column < 0 || column > 1 || row < 0 || row > 1) throw new ArgumentOutOfRangeException();
            return new RectangleF(Logo.Left + column * 21 * Unit, Logo.Top + row * 21 * Unit,
                17 * Unit, 17 * Unit);
        }
    }
}
