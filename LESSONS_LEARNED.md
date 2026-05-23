# Lessons Learned

Real bugs, surprises, and hard-won knowledge from building this library. Documented so future contributors (human or AI) don't repeat the same mistakes.

---

## 1. Kotlin `return` Inside `by` Delegation Object Expression

**Bug:** `'return' is prohibited here` compile error in `PointerLocationManager.kt`.

**What happened:** We tried to write `originalCallback ?: return` inside the `by` clause of an anonymous object:

```kotlin
// ❌ This doesn't compile
window.callback = object : Window.Callback by (window.callback ?: return) { ... }
```

Kotlin does not allow `return` statements inside object expressions used with `by` delegation. The `return` would need to exit the enclosing function, but the compiler can't guarantee that's safe inside an initializer expression.

**Fix:** Extract the value into a local variable first, then use the variable in `by`:

```kotlin
// ✅ This works
val delegate = window.callback ?: return
window.callback = object : Window.Callback by delegate { ... }
```

**Lesson:** In Kotlin, always extract nullable values with early returns before using them in `by` delegation or object expression initializers.

---

## 2. VelocityTracker Recycled Before Reading Final Velocity

**Bug:** `Xv` and `Yv` were always `0` after releasing the finger.

**What happened:** On Android, `velocityTracker.recycle()` was called inside `ACTION_UP` before we read the velocity values:

```kotlin
// ❌ Wrong order — velocity is lost after recycle()
MotionEvent.ACTION_UP -> {
    velocityTracker?.recycle()  // releases the tracker back to the pool
    velocityTracker = null
    // xVelocity and yVelocity are now stale (or 0)
}
```

`recycle()` returns the tracker to a shared pool and clears its internal state. Any subsequent read returns 0.

On iOS, we had a similar bug: velocity was explicitly reset to `0` in the `.ended` case.

**Fix:** Compute velocity *before* recycling:

```kotlin
// ✅ Read first, recycle after
velocityTracker?.computeCurrentVelocity(1)
xVelocity = velocityTracker?.xVelocity ?: xVelocity
yVelocity = velocityTracker?.yVelocity ?: yVelocity
velocityTracker?.recycle()
velocityTracker = null
```

On iOS: removed the explicit velocity reset in `.ended`/`.cancelled` so the last computed velocity persists in the data bar.

**Lesson:** Always read values from pooled/recycled objects *before* recycling them. Think of `recycle()` as `free()` — the object is invalid after.

---

## 3. VelocityTracker Units: Pixels Per Millisecond, Not Per Second

**Bug:** Xv/Yv values were thousands of times larger than Android's native "Pointer Location" developer option.

**What happened:** `VelocityTracker.computeCurrentVelocity(units)` takes a `units` parameter that scales the result. We initially used `1000` (pixels/second), but Android's native implementation uses `1` (pixels/millisecond).

```kotlin
// ❌ pixels per second — values like 1500.0
velocityTracker?.computeCurrentVelocity(1000)

// ✅ pixels per millisecond — values like 1.500 (matching native)
velocityTracker?.computeCurrentVelocity(1)
```

The native "Pointer Location" shows values like `0.xxx` for normal speed and `~20.x` for extremely fast swipes.

On iOS, the manual velocity computation needed the same scale: `(dx in points) / (dt in milliseconds)`.

**Lesson:** When replicating a system feature, match its exact units. Check the source or carefully observe the original's output range before assuming.

---

## 4. iOS Pressure Is Always 0 on Non-3D-Touch Devices

**Bug:** The "Prs" column always showed `0.00` on newer iPhones (XR, 11, 12, 13, 14, 15, 16).

**What happened:** `UITouch.force` is always 0 on devices without 3D Touch hardware. Only iPhone 6s through iPhone XS have 3D Touch. Newer devices use Haptic Touch (a software feature based on long press duration, not physical force).

We initially tried to estimate pressure from touch area, but that produced inaccurate values.

**Fix:** Detect 3D Touch hardware by checking `touch.maximumPossibleForce > 0`. If unavailable, completely remove the "Prs" column from the data bar instead of showing misleading zeros:

```swift
if touch.maximumPossibleForce > 0 {
    has3DTouch = true
    lastPressure = touch.force / touch.maximumPossibleForce
}

// In drawDataBar:
if has3DTouch {
    metrics.append(Metric(label: "Prs", ...))
}
```

**Lesson:** Don't show unavailable hardware data with a fallback — it's misleading. Either show the real value or hide the metric entirely. Test on actual hardware, not just simulators (simulators may behave differently for hardware-dependent APIs).

---

## 5. iOS Touch Size Much Larger Than Android

**Bug:** Normal finger tap showed `Size: 0.26–0.36` on iOS vs `0.07` on Android.

**What happened:** We were normalizing iOS `majorRadius` by dividing by `100.0`, but `majorRadius` is in points (typically 20–30 for a normal finger) while Android's `getSize()` is pre-normalized to 0–1.

Also, `majorRadius` includes sensor uncertainty — it overestimates the actual contact area. `majorRadiusTolerance` indicates how uncertain the measurement is.

**Fix:** Two changes:
1. Subtract `majorRadiusTolerance` for a tighter estimate of actual contact area.
2. Increase the divisor from 100 to 400 (empirically calibrated):

```swift
let adjustedRadius = max(touch.majorRadius - touch.majorRadiusTolerance, 0)
let normalizedSize = min(adjustedRadius / 400.0, 1.0)
```

**Lesson:** Cross-platform normalization requires empirical calibration. Don't assume APIs from different platforms have the same scale. Test with actual fingers on both platforms side-by-side.

---

## 6. iOS Touch Area Direction Does Not Rotate

**Bug:** On Android, rotating your finger on screen changes the ellipse orientation. On iOS, the ellipse always stayed vertical.

**What happened:** Android's `MotionEvent` provides `getTouchMajor()`, `getTouchMinor()`, and `getOrientation()` — three values that describe a rotated ellipse. iOS's `UITouch` only provides `majorRadius` (a single scalar). There is no minor axis or orientation data for finger touches on iOS.

We initially tried to draw a fixed-orientation ellipse, which looked incorrect when the user touched horizontally.

**Fix:** Changed iOS touch area from an ellipse to a **circle** using `majorRadius`. This is less information than Android but doesn't look "wrong":

```swift
// Circle instead of ellipse — honest about what we know
let circle = CGRect(x: loc.x - r, y: loc.y - r, width: r * 2, height: r * 2)
ctx.fillEllipse(in: circle)
```

**Lesson:** When cross-platform data parity is impossible, choose an honest representation over a broken one. A circle that's correct is better than an ellipse that's always wrong.

---

## 7. iOS Touch Area Size Jumps Between Frames

**Bug:** The touch area circle on iOS changed size abruptly (jumping between small and large) instead of transitioning smoothly like Android.

**What happened:** iOS `majorRadius` can fluctuate significantly between consecutive touch samples. Android's touch sensor data is internally smoothed, but iOS reports raw sensor readings.

**Fix:** Applied exponential moving average (EMA) to smooth radius transitions:

```swift
private static let radiusSmoothingFactor: CGFloat = 0.3

let prevSmoothed = activePointers[id]?.smoothedMajorRadius ?? adjustedRadius
let smoothed = prevSmoothed + (adjustedRadius - prevSmoothed) * radiusSmoothingFactor
```

A factor of 0.3 means each new sample contributes 30% to the smoothed value and the previous value contributes 70%, creating a gradual transition.

**Lesson:** When raw sensor data is jittery, apply smoothing. Exponential moving average is a simple and effective choice for real-time visualization.

---

## 8. iOS 6+ Fingers Causes P: 0/0 and Everything Stops

**Bug:** Touching with 6 or more fingers caused the "P" metric to show "0/0" and all drawing stopped.

**What happened:** When iOS cancels all touches (which it does when too many fingers are detected — a system gesture threshold), our code removed all entries from `activePointers`. The `maxPointerCount` was reset to 0 on the next `.began` event because we checked `activePointers.isEmpty` and reset unconditionally.

The flow was:
1. 6 fingers touch → system cancels all touches (`.cancelled`)
2. `activePointers` becomes empty, `maxPointerCount` stays at 6
3. A new touch begins → `activePointers.isEmpty` is true → `maxPointerCount = 0` ← wrong!
4. Display shows `P: 0/0`

**Fix:** Reset `maxPointerCount` only at the start of a genuinely **new** gesture (when `activePointers` is empty AND a `.began` arrives), and set it to 0 before incrementing:

```swift
case .began:
    if activePointers.isEmpty {
        maxPointerCount = 0  // reset for new gesture
        pathSegments.removeAll()
    }
    activePointers[id] = data
    maxPointerCount = max(maxPointerCount, activePointers.count)
```

**Lesson:** Be careful about when to reset aggregate state. "All fingers lifted" doesn't mean the gesture conceptually ended — the system may have cancelled it. Only reset on a clear new-gesture signal.

---

## 9. iOS UI Breaks After Device Rotation

**Bug:** After rotating the device, the overlay UI appeared distorted/mispositioned, and required a touch to force a re-render.

**What happened:** We initially set the drawing view's frame inside `UIWindow.layoutSubviews()`. On modern iOS (especially with UIWindowScene), `layoutSubviews` on a `UIWindow` is not reliably called during rotation. The drawing view kept its old frame and coordinate system.

**Fix:** Introduced an `OverlayViewController` as the window's `rootViewController`. UIKit reliably calls `viewDidLayoutSubviews()` on view controllers during rotation:

```swift
private class OverlayViewController: UIViewController {
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        drawingView.frame = view.bounds
        drawingView.setNeedsDisplay()
    }
}
```

Additionally, the drawing view overrides `safeAreaInsetsDidChange()` and observes `bounds` changes to clear stale drawing state:

```swift
override var bounds: CGRect {
    didSet {
        if bounds.size != oldValue.size {
            pathSegments.removeAll()
            activePointers.removeAll()
            // ... clear all stale state
        }
    }
}
```

**Lesson:** On iOS, always use a `UIViewController` for layout management — it receives reliable lifecycle callbacks. Direct UIWindow/UIView layout overrides are unreliable in the UIWindowScene era. Also, always clear coordinate-dependent state on rotation.

---

## 10. Android Data Bar Behind Status Bar / Notch

**Bug:** The data bar was drawn behind (underneath) the status bar/notch instead of below it.

**What happened:** We initially used a hardcoded status bar height lookup:

```kotlin
val statusBarHeight = resources.getDimensionPixelSize(
    resources.getIdentifier("status_bar_height", "dimen", "android")
)
```

This doesn't account for display cutouts (notches), navigation bar changes, or orientation-dependent safe areas.

**Fix:** Replaced with the `WindowInsets` API, which dynamically provides accurate safe area information:

```kotlin
setOnApplyWindowInsetsListener { _, insets ->
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        val systemBars = insets.getInsets(
            WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
        )
        safeInsetTop = systemBars.top
    } else {
        safeInsetTop = insets.displayCutout?.safeInsetTop
            ?: insets.systemWindowInsetTop
    }
    invalidate()
    insets
}
```

Also needed to call `requestApplyInsets()` on attach to ensure insets arrive immediately (otherwise the first render may have stale values).

**Lesson:** Never hardcode system UI dimensions. Use `WindowInsets` on Android and `safeAreaInsets` on iOS. They handle notches, cutouts, orientation changes, and foldable devices correctly.

---

## 11. Data Bar Layout Shifts When Values Change

**Bug:** The data bar columns jumped around as numeric values changed (e.g., going from `9.0` to `10.0` made the column wider).

**What happened:** We initially sized each column based on the rendered text width. As values changed length (e.g., single digit to double digit, or adding decimal places), column widths fluctuated.

**Fix:** Use fixed equal-width columns: `columnWidth = screenWidth / numColumns`. Every column gets the same width regardless of content. Combined with a monospace font, this eliminates all layout shift:

```kotlin
val columnWidth = width.toFloat() / metrics.size
```

**Lesson:** For real-time data displays, use fixed-width layouts. Never size containers based on content that changes every frame.

---

## 12. dX/dY Showing Integer-Only Values

**Bug:** dX/dY values always showed `.0` decimal (e.g., `42.0`, `73.0`).

**What happened:** We were computing deltas from integer pixel positions. On Android, `MotionEvent.getX()` returns float coordinates, but if the start/end positions were captured from events where sub-pixel precision was lost (e.g., only capturing on ACTION_DOWN/UP without the fractional part), the delta was always integer.

**Fix:** The values are actually correct — Android's native "Pointer Location" also shows `.0` most of the time for dX/dY because these are the distance between finger-down and finger-up positions, which are typically on integer pixel boundaries. The `.1f` format string correctly shows one decimal place.

**Lesson:** Before assuming a value is wrong, check the native reference implementation. Sometimes the "bug" is just how the data works.

---

## Summary of Prevention Strategies

| Category | Strategy |
|----------|----------|
| **Resource lifecycle** | Always read before recycle/release. Think of `recycle()` as `free()`. |
| **Cross-platform parity** | Don't assume same API names mean same scales. Empirically compare outputs. |
| **Platform limitations** | When data isn't available, hide the feature instead of showing wrong data. |
| **Sensor data** | Apply smoothing (EMA) when raw values are jittery. |
| **Layout** | Use fixed-width layouts for real-time data. Never size based on changing content. |
| **Safe areas** | Use dynamic inset APIs (`WindowInsets`, `safeAreaInsets`), never hardcode dimensions. |
| **iOS rotation** | Use `UIViewController` for layout callbacks, not `UIWindow.layoutSubviews`. |
| **State management** | Be precise about when to reset aggregate state (e.g., max pointer count). |
| **Kotlin gotchas** | Extract nullable values before using in `by` delegation or object expressions. |
| **Units** | Always verify units match the reference implementation (px/ms vs px/s, points vs pixels). |
