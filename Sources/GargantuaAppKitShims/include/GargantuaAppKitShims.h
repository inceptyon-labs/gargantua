#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lower the macOS NSToolTipManager initial delay so the first tooltip in a
// session feels as fast as subsequent ones. Returns true on success, false if
// the private selector path is unavailable (e.g. AppKit deprecates it). Wraps
// the call in @try/@catch so a missing selector or KVC mismatch can never
// crash the host app.
bool GargantuaSetNativeToolTipDelay(double seconds);

#ifdef __cplusplus
}
#endif
