// Public API for the library.
// These are thin wrappers that call the native module methods.
// The native module handles all the heavy lifting (overlay, drawing, touch interception).

import PointerLocation from './NativePointerLocation';

/**
 * Enable or disable the "Show Taps" visual indicator.
 * When enabled, draws a semi-transparent circle at every active touch point
 * with a fade-out animation on release.
 */
export function setShowTaps(enabled: boolean): void {
  // Calls native: Android → PointerLocationModule.setShowTaps()
  //               iOS    → PointerLocation.mm setShowTaps:
  PointerLocation.setShowTaps(enabled);
}

/**
 * Enable or disable the "Pointer Location" developer overlay.
 * When enabled, renders:
 * - A data bar showing real-time touch metrics (P, X/dX, Y/dY, Xv, Yv, Prs, Size)
 * - Blue crosshair lines tracking the primary touch point
 * - A velocity-colored gesture path (red=slow, blue=fast)
 * - A touch contact area indicator (ellipse on Android, circle on iOS)
 */
export function setPointerLocation(enabled: boolean): void {
  // Calls native: Android → PointerLocationModule.setPointerLocation()
  //               iOS    → PointerLocation.mm setPointerLocation:
  PointerLocation.setPointerLocation(enabled);
}
