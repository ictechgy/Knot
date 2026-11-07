// SPDX-License-Identifier: GPL-3.0-only
using System;

namespace Knot.NativePreview
{
    internal static class RegisteredConnectionResume
    {
        internal static bool TryResume(bool ownerRequested, bool closing, bool transportEligible,
            Action constructHost, Func<bool> hasRegisteredDevices = null)
        {
            if (!ownerRequested || closing || !transportEligible) return false;
            try
            {
                // A run's cached availability can outlive authenticated remote
                // revocation. Re-read immediately before automatic construction.
                if (!(hasRegisteredDevices == null ? NativeTrustedDevices.List().Count != 0 : hasRegisteredDevices())) return false;
            }
            catch { return false; }
            constructHost(); return true;
        }
    }
}
