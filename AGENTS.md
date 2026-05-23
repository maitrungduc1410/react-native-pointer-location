# AGENTS.md

Guidelines for AI agents working on this codebase.

## Project Overview

React Native TurboModule library that replicates Android's "Show Taps" and "Pointer Location" developer options on both Android and iOS. All drawing happens in native code — no Fabric Views.

## Architecture

```
src/                          # TypeScript (public API + native module spec)
├── index.tsx                 # Public API: setShowTaps(), setPointerLocation()
└── NativePointerLocation.ts  # TurboModule spec with old arch fallback

android/
├── build.gradle              # Conditional new/old arch via isNewArchitectureEnabled()
├── src/main/java/com/pointerlocation/
│   ├── PointerLocationModule.kt       # RN module entry point (extends PointerLocationSpec)
│   ├── PointerLocationPackage.kt      # RN package registration
│   ├── PointerLocationManager.kt      # Singleton: overlay lifecycle + touch interception
│   └── PointerLocationOverlayView.kt  # Canvas drawing (data bar, crosshairs, path, taps)
├── src/newarch/java/.../PointerLocationSpec.kt  # Extends codegen NativePointerLocationSpec
└── src/oldarch/java/.../PointerLocationSpec.kt  # Extends ReactContextBaseJavaModule

ios/
├── PointerLocation.h                  # Header (new arch only, guarded by RCT_NEW_ARCH_ENABLED)
├── PointerLocation.mm                 # ObjC++ bridge (new arch TurboModule / old arch RCT_EXPORT)
├── PointerLocationManager.swift       # Singleton: overlay window lifecycle + sendEvent swizzle
├── PointerLocationOverlayWindow.swift # Non-interactive UIWindow above all content
└── PointerLocationDrawingView.swift   # Core Graphics drawing (data bar, crosshairs, path, taps)
```

## Key Conventions

### Both Architectures
- The library supports both old and new React Native architectures.
- Android: `src/newarch` and `src/oldarch` directories contain arch-specific `PointerLocationSpec.kt`. The `build.gradle` switches source sets based on `newArchEnabled` property.
- iOS: `PointerLocation.mm` uses `#ifdef RCT_NEW_ARCH_ENABLED` to compile either TurboModule or bridge code.
- TypeScript: `NativePointerLocation.ts` checks `global.__turboModuleProxy` to pick TurboModuleRegistry vs NativeModules.

### Native Code
- **All UI work on main thread.** Module methods dispatch to the manager on the UI thread (Android: `runOnUiThread`, iOS: `dispatch_async(main_queue)`).
- **Overlay must never consume touches.** Android: `isClickable=false`, `isFocusable=false`. iOS: `isUserInteractionEnabled=false`, `hitTest` returns `nil`.
- **Touch interception is read-only.** Android wraps `Window.Callback` and always calls the original `dispatchTouchEvent`. iOS swizzles `sendEvent` and always calls the original implementation.
- **Resource lifecycle.** The overlay and touch interceptor are only attached when at least one feature is enabled, and detached when both are disabled.

### Drawing
- Android uses `Canvas` API in `onDraw()`.
- iOS uses Core Graphics (`CGContext`) in `draw(_:)`.
- Both platforms use equal-width columns in the data bar to prevent layout shift.
- Gesture path segments are stored per-line-segment with pre-computed velocity colors (red=slow, blue=fast) to support multi-finger paths.
- Tap fade-out uses `ValueAnimator` (Android) / `CABasicAnimation` (iOS).

### Platform Differences to Be Aware Of
- iOS has no finger touch orientation (`UITouch` only provides `majorRadius`), so the touch area is drawn as a circle instead of a rotated ellipse.
- iOS pressure (Prs) is only available on 3D Touch devices. On non-3D-Touch devices, the column is omitted entirely.
- iOS `majorRadius` overestimates contact size; we subtract `majorRadiusTolerance` and normalize by dividing by 400 to approximate Android's `getSize()` scale.
- iOS velocity is manually computed from position/timestamp deltas. Android uses `VelocityTracker.computeCurrentVelocity(1)` (pixels/millisecond).

### Safe Area
- Android: Uses `WindowInsets` API (`systemBars | displayCutout`) to position the data bar below the status bar/notch. Re-requests insets on size change.
- iOS: Uses `safeAreaInsets.top`. Overrides `safeAreaInsetsDidChange()` and `bounds` setter to handle rotation.

## Required Reading

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — How the overlay, touch interception, drawing pipeline, and dual-arch support work. Read before making structural changes.
- **[LESSONS_LEARNED.md](./LESSONS_LEARNED.md)** — Real bugs encountered during development with root causes and fixes. **Read this before modifying native code** to avoid repeating known mistakes. Key pitfalls:
  - VelocityTracker must be read before recycle() (Android)
  - iOS has no finger orientation or pressure on modern devices — hide features, don't fake them
  - Use WindowInsets / safeAreaInsets for safe area — never hardcode
  - Use UIViewController for iOS rotation callbacks, not UIWindow.layoutSubviews
  - Kotlin `return` is prohibited inside `by` delegation object expressions
  - Cross-platform value normalization requires empirical calibration (iOS majorRadius / 400 ≈ Android getSize)

## Testing

Run the example app:
```bash
cd example
yarn start
```

Both features should be tested independently and together. Key scenarios:
- Toggle each feature on/off
- Multi-finger touch (2-5+ fingers)
- Device rotation
- Verify touches pass through to the app UI underneath
