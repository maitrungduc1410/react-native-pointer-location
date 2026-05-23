# Architecture

This document explains how `react-native-pointer-location` works under the hood — the overlay mechanism, touch interception strategy, drawing pipeline, and how the pieces connect across JavaScript, Android (Kotlin), and iOS (Swift/ObjC++).

## Overview

The library has three layers:

```
┌─────────────────────────────────────────────────────────┐
│  JavaScript                                             │
│  setShowTaps(true) / setPointerLocation(true)           │
│  ↓                                                      │
│  NativePointerLocation.ts → TurboModule or NativeModules│
└──────────────────────────┬──────────────────────────────┘
                           │  (native call)
┌──────────────────────────▼──────────────────────────────┐
│  Native Module (entry point)                            │
│  Android: PointerLocationModule.kt                      │
│  iOS:     PointerLocation.mm → PointerLocationManager   │
│  Dispatches to UI thread, delegates to Manager singleton│
└──────────────────────────┬──────────────────────────────┘
                           │  (main thread)
┌──────────────────────────▼──────────────────────────────┐
│  Native Drawing + Touch Interception                    │
│  Android: PointerLocationOverlayView (Canvas API)       │
│  iOS:     PointerLocationDrawingView (Core Graphics)    │
│  Managed by PointerLocationManager singleton            │
└─────────────────────────────────────────────────────────┘
```

## Dual Architecture Support

The library supports both React Native's old (Bridge) and new (TurboModule) architectures without any user configuration.

### How it auto-detects

**JavaScript side** (`NativePointerLocation.ts`):
- Checks `global.__turboModuleProxy` — this global is set by React Native only when TurboModules are enabled.
- If present: uses `TurboModuleRegistry.getEnforcing('PointerLocation')` (new arch).
- If absent: uses `NativeModules.PointerLocation` (old arch).

**Android side**:
- `build.gradle` defines `isNewArchitectureEnabled()` which checks the `newArchEnabled` Gradle property.
- Conditional `sourceSets`: `src/newarch/java` (extends codegen-generated `NativePointerLocationSpec`) or `src/oldarch/java` (extends `ReactContextBaseJavaModule`).
- Both provide an abstract class called `PointerLocationSpec`, so `PointerLocationModule` extends the same name regardless of architecture.
- `BuildConfig.IS_NEW_ARCHITECTURE_ENABLED` is used in `PointerLocationPackage` to set the `isTurboModule` flag in `ReactModuleInfo`.

**iOS side**:
- `PointerLocation.mm` uses `#ifdef RCT_NEW_ARCH_ENABLED`:
  - New arch: implements `NativePointerLocationSpec` protocol and `getTurboModule:`.
  - Old arch: uses `RCT_EXPORT_MODULE()` and `RCT_EXPORT_METHOD()` macros.
- Both paths dispatch to the same Swift `PointerLocationManager.shared` on the main queue.

## The Overlay

The overlay must render above everything in the app — including React Native modals, navigation headers, alerts, and keyboard — while never intercepting or consuming touches.

### Android: View in DecorView

Android's `DecorView` is the root `ViewGroup` of every Activity's window. It contains the status bar background, the app's content view, and the navigation bar background. We add our `PointerLocationOverlayView` directly to the DecorView:

```
DecorView (FrameLayout, full screen)
├── StatusBarBackground
├── ContentView (your React Native app)
├── NavigationBarBackground
└── PointerLocationOverlayView ← added here
    - LayoutParams: MATCH_PARENT × MATCH_PARENT
    - elevation: Float.MAX_VALUE (renders above siblings)
    - isClickable: false
    - isFocusable: false
```

**Why DecorView and not WindowManager?**
We could use `WindowManager.addView()` with `TYPE_APPLICATION_OVERLAY`, but that requires the `SYSTEM_ALERT_WINDOW` permission (a scary permission that users must grant manually). Adding to DecorView requires no permissions and is simpler.

**Why max elevation?**
Android uses elevation for z-ordering within a ViewGroup. `Float.MAX_VALUE` guarantees our view renders above any other view in the DecorView, including React Native's modal overlay views.

**How touches pass through:**
Setting `isClickable = false` and `isFocusable = false` prevents the view from participating in Android's touch dispatch. When the system performs hit testing, our view reports "I don't handle touches" and the event continues to views underneath.

### iOS: Separate UIWindow

iOS uses a fundamentally different architecture. There is no single "root view" you can add to. Instead, iOS has multiple `UIWindow` objects, each with a `windowLevel` that determines z-order:

```
Window stack (higher windowLevel = renders on top):
┌──────────────────────────────────────────┐
│ PointerLocationOverlayWindow             │ windowLevel = .statusBar + 100 (1100)
│   └── OverlayViewController             │
│       └── PointerLocationDrawingView     │
├──────────────────────────────────────────┤
│ System Alert Window                      │ windowLevel = .alert (2000) — we're below this
├──────────────────────────────────────────┤
│ Status Bar Window                        │ windowLevel = .statusBar (1000)
├──────────────────────────────────────────┤
│ App Main Window                          │ windowLevel = .normal (0)
│   └── React Native root view            │
└──────────────────────────────────────────┘
```

**Why a UIWindow?**
On iOS, you cannot add a view to another window and have it render above that window's content in all cases. Modals and presented view controllers create new layers that would cover a view added to the main window. A separate UIWindow with a high windowLevel is the only reliable way to render above everything.

**How touches pass through:**
Two mechanisms ensure complete pass-through:
1. `isUserInteractionEnabled = false` — the standard UIKit property that disables the entire hit-test tree.
2. `hitTest(_:with:)` returns `nil` — a belt-and-suspenders override. Even if `isUserInteractionEnabled` were somehow toggled, `hitTest` explicitly says "nothing in this window handles touches."

**Rotation handling:**
The window uses an `OverlayViewController` as its `rootViewController`. UIKit automatically calls `viewDidLayoutSubviews()` on the VC during device rotation, which resizes the drawing view and triggers a redraw. This is more reliable than overriding `layoutSubviews` on UIWindow, which isn't consistently called in modern iOS.

## Touch Interception

Both platforms need to observe every touch event without consuming it. The strategies differ because the OS architectures differ.

### Android: Window.Callback Wrapping

Every Android Activity has a `Window.Callback` — an interface that receives all input events before they enter the view hierarchy. `dispatchTouchEvent` on this callback is the very first method called for any touch.

We wrap the existing callback using **Kotlin interface delegation** (`by` keyword):

```kotlin
val delegate = window.callback  // save original
window.callback = object : Window.Callback by delegate {
    override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
        event?.let { overlayView?.updateTouchData(it) }  // observe
        return delegate.dispatchTouchEvent(event)          // pass through
    }
}
```

The `by delegate` clause makes Kotlin auto-implement every method in `Window.Callback` by delegating to `delegate`. We only override `dispatchTouchEvent`. All other callbacks (key events, menu events, focus changes) pass through unchanged.

**Lifecycle:** The wrapper is installed on `attach()` and the original callback is restored on `detach()`.

### iOS: UIApplication.sendEvent Swizzling

iOS has no equivalent to `Window.Callback`. All touch events flow through `UIApplication.sendEvent(_:)` before reaching the responder chain. We intercept this using **Objective-C runtime method swizzling**.

Swizzling swaps the implementations of two methods at runtime:

```
Before swizzle:
  Selector "sendEvent:"       → impl_A (Apple's original code)
  Selector "pl_sendEvent:"    → impl_B (our code)

After method_exchangeImplementations:
  Selector "sendEvent:"       → impl_B (our code runs first!)
  Selector "pl_sendEvent:"    → impl_A (Apple's original code)
```

So when iOS calls `sendEvent:`, it runs our code. Our code calls `self.pl_sendEvent(event)`, which — due to the swap — runs Apple's original implementation. This looks recursive but isn't.

```swift
extension UIApplication {
    @objc func pl_sendEvent(_ event: UIEvent) {
        PointerLocationManager.shared.handleEvent(event)  // observe
        pl_sendEvent(event)  // calls original sendEvent (implementations are swapped)
    }
}
```

**Why swizzling?**
- `UIGestureRecognizer` can observe touches but can't guarantee seeing every touch globally.
- Subclassing `UIApplication` requires modifying the app's `main.swift`, which isn't feasible for a library.
- Swizzling `sendEvent` is the standard pattern used by analytics SDKs, crash reporters, and developer tools.

**Lifecycle:** The swizzle is installed once and never removed. Unswizzling is risky because other libraries may have swizzled after us (creating a chain). Instead, `handleEvent()` checks the feature flags and returns immediately when disabled — zero overhead.

## Drawing Pipeline

Both platforms use immediate-mode drawing: every touch event triggers a full redraw of all visual layers.

### Android: Canvas API

```
MotionEvent arrives via Window.Callback
    ↓
updateTouchData(event)
    - Updates activePointers map
    - Feeds VelocityTracker
    - Appends PathSegments with velocity-interpolated colors
    - Calls invalidate()
    ↓
Android schedules onDraw(canvas)
    ↓
onDraw paints layers in order:
    1. Data bar (drawDataBar)
    2. Crosshairs (drawCrosshairs)
    3. Touch area ellipse (drawTouchArea)
    4. Gesture path segments (drawGesturePath)
    5. Active tap circles (drawActiveTaps)
    6. Fading tap circles (drawFadingTaps)
```

`invalidate()` marks the view as needing a redraw. Android's choreographer calls `onDraw()` on the next VSYNC, hardware-accelerating the Canvas operations on the GPU.

### iOS: Core Graphics

```
UIEvent arrives via swizzled sendEvent
    ↓
processTouches(touches, in: window)
    - Updates activePointers dictionary
    - Computes velocity manually from timestamps
    - Appends PathSegments with velocity-interpolated colors
    - Calls setNeedsDisplay()
    ↓
UIKit schedules draw(_:)
    ↓
draw(_ rect:) paints layers via CGContext:
    1. Data bar (drawDataBar)
    2. Crosshairs (drawCrosshairs)
    3. Touch area circle (drawTouchArea)
    4. Gesture path segments (drawGesturePath)
    5. Active tap circles (drawActiveTaps)
    // Fading taps use CAShapeLayer (separate from draw cycle)
```

`setNeedsDisplay()` marks the view as dirty. UIKit calls `draw(_:)` on the next display cycle with a `CGContext`.

### Key Difference: Fading Taps

- **Android:** Uses `ValueAnimator` to drive alpha from 128→0 over 200ms. Each animation frame calls `invalidate()` to trigger a redraw, and `drawFadingTaps()` reads the current alpha.
- **iOS:** Uses `CAShapeLayer` + `CABasicAnimation`. The layer is added to the view's layer hierarchy, and Core Animation drives the opacity transition on a separate render thread. This is more efficient (no main thread involvement per frame) but requires manual layer cleanup.

## Data Bar Metrics

The data bar displays 7 columns (6 on iOS without 3D Touch):

| Metric | While touching | After release | Red highlight |
|--------|---------------|---------------|---------------|
| **P** | `active/max` | `0/max` | Never |
| **X/dX** | Absolute X position | Delta from start X | Full column, only after release |
| **Y/dY** | Absolute Y position | Delta from start Y | Full column, only after release |
| **Xv** | Live X velocity (px/ms) | Last velocity | Never |
| **Yv** | Live Y velocity (px/ms) | Last velocity | Never |
| **Prs** | Normalized pressure 0–1 | Last pressure | Proportional fill (persists) |
| **Size** | Normalized contact size 0–1 | Last size | Proportional fill (persists) |

All columns have equal width (`screenWidth / numColumns`) to prevent layout shift when values change.

## Velocity Computation

- **Android:** Uses the built-in `VelocityTracker` class. Calling `computeCurrentVelocity(1)` returns velocity in **pixels per millisecond**. The tracker uses polynomial curve fitting across multiple samples for smooth results.
- **iOS:** No built-in velocity tracker. We manually compute `(currentPos - prevPos) / (currentTime - prevTime)` from consecutive `UITouch` samples, converting the time delta from seconds to milliseconds.

Both platforms preserve the last velocity after finger release (matching Android's native behavior).

## Velocity-Colored Path

Gesture paths are drawn as individual line segments, each colored based on instantaneous speed:

```
speed = sqrt(dx² + dy²)    // distance between consecutive samples
t = clamp(speed / SPEED_THRESHOLD, 0, 1)
color = lerp(RED, ROYAL_BLUE, t)
```

`SPEED_THRESHOLD` (30 points) is the distance that maps to full blue. Below that, colors interpolate. Each segment is stored with its pre-computed color so multi-finger paths work correctly — each finger has its own chain of segments.

## Touch Area

- **Android:** Draws a **rotated ellipse** using `MotionEvent.getTouchMajor()` (major axis), `getTouchMinor()` (minor axis), and `getOrientation()` (rotation angle in radians). The canvas is translated to the touch point, rotated, and the ellipse is drawn axis-aligned.
- **iOS:** Draws a **circle** using `UITouch.majorRadius`. iOS doesn't expose minor axis or finger orientation for touches. The radius is smoothed via exponential moving average to prevent jitter.

### iOS Size Normalization

iOS `majorRadius` is in points and doesn't directly map to Android's normalized `getSize()` (0–1 range). We normalize:

```swift
adjustedRadius = max(majorRadius - majorRadiusTolerance, 0)  // tighter estimate
normalizedSize = min(adjustedRadius / 400.0, 1.0)            // calibrated to match Android
```

The divisor 400 was empirically chosen so that a normal finger tap produces ~0.07 on both platforms.

## Safe Area Handling

The data bar must appear below the status bar, notch, or display cutout on all orientations.

- **Android:** Uses `WindowInsets` API via `setOnApplyWindowInsetsListener`. On API 30+, combines `systemBars()` and `displayCutout()` inset types. On older APIs, falls back to `displayCutout?.safeInsetTop` or `systemWindowInsetTop`. The listener fires on initial layout and rotation; we also call `requestApplyInsets()` on attach.
- **iOS:** Uses `safeAreaInsets.top` from the view, which UIKit automatically updates. The `OverlayViewController` triggers redraws in `viewDidLayoutSubviews()`, and the drawing view overrides `safeAreaInsetsDidChange()` for additional safety.

Both platforms clear all drawing state (paths, taps, pointers) on size change/rotation because coordinates from the previous orientation are invalid.

## Resource Management

The overlay and touch interceptor are not always active:

```
setShowTaps(true)  → attach overlay + interceptor (if not already attached)
setShowTaps(false) → if pointer location also false → detach everything
```

**Attach** creates the overlay view/window and installs the touch interceptor.
**Detach** removes the overlay, cancels animations, releases trackers, and (on Android) restores the original Window.Callback.

This ensures zero resource usage when both features are disabled.

### Singleton Pattern

Both platforms use a singleton (`PointerLocationManager`) because React Native can recreate module instances on hot reload. The singleton preserves overlay state across recreations. The Activity/Window reference is held via `WeakReference` (Android) or implicitly managed (iOS — the overlay window is set to nil on detach).

## File Map

```
src/
├── index.tsx                   Public API: setShowTaps(), setPointerLocation()
└── NativePointerLocation.ts    TurboModule spec with old arch fallback

android/src/main/java/com/pointerlocation/
├── PointerLocationModule.kt       Entry point, dispatches to Manager on UI thread
├── PointerLocationPackage.kt      RN package registration with arch-aware isTurboModule flag
├── PointerLocationManager.kt      Singleton: overlay lifecycle + Window.Callback wrapping
└── PointerLocationOverlayView.kt  Canvas drawing, touch processing, VelocityTracker

android/src/newarch/java/.../PointerLocationSpec.kt  Extends codegen NativePointerLocationSpec
android/src/oldarch/java/.../PointerLocationSpec.kt  Extends ReactContextBaseJavaModule

ios/
├── PointerLocation.h                  Header for TurboModule (new arch only)
├── PointerLocation.mm                 ObjC++ bridge (new arch TurboModule / old arch RCT_EXPORT)
├── PointerLocationManager.swift       Singleton: overlay window lifecycle + sendEvent swizzle
├── PointerLocationOverlayWindow.swift UIWindow + OverlayViewController for rotation handling
└── PointerLocationDrawingView.swift   Core Graphics drawing, touch processing, manual velocity
```
