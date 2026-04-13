import UIKit

/**
 * Singleton managing the overlay window lifecycle and global touch interception on iOS.
 *
 * ## Why a singleton?
 * React Native can recreate Objective-C module instances on hot reload, but we need the
 * overlay state (window, swizzle, feature flags) to persist. The singleton holds the
 * actual state; the ObjC bridge (PointerLocation.mm) just calls through to it.
 *
 * ## How the overlay works (iOS vs Android)
 * On iOS, we cannot add a view to another window's view hierarchy and have it draw on top.
 * Unlike Android where DecorView is a single root for everything, iOS uses a multi-window
 * architecture. Each UIWindow has its own z-level (windowLevel). To draw above ALL app content
 * (including modals, alerts, keyboard), we create a separate UIWindow with a windowLevel
 * higher than .statusBar. This is fundamentally different from Android where we just add
 * a view to the DecorView with max elevation.
 *
 * ## How touch interception works
 * iOS doesn't have an equivalent to Android's Window.Callback.dispatchTouchEvent.
 * Instead, all touch events flow through UIApplication.sendEvent(_:) before being
 * dispatched to the responder chain. We use Objective-C runtime method swizzling to
 * replace sendEvent's implementation with our own, which calls handleEvent() first
 * and then invokes the original sendEvent.
 *
 * ### Method swizzling explained
 * method_exchangeImplementations(A, B) swaps the implementations of two methods:
 * - Before swizzle: sendEvent → original impl, pl_sendEvent → our impl
 * - After swizzle:  sendEvent → our impl, pl_sendEvent → original impl
 * So when iOS calls sendEvent, it actually runs our code. When our code calls
 * pl_sendEvent, it actually runs the original sendEvent. This looks recursive
 * but isn't — the method names and implementations are crossed.
 *
 * ## Resource management
 * - Both features disabled → overlay window is hidden and released (nil)
 * - Either feature enabled → overlay window is created and shown
 * - The swizzle is installed once and never removed. This is safe because handleEvent()
 *   checks the feature flags before doing any work, so when disabled it's a no-op.
 *   Unswizzling is risky because other libraries might have swizzled after us.
 *
 * ## Touch coordinate system
 * Touch locations are resolved against the app's main window (not the overlay window)
 * so coordinates match what the app sees. The overlay window is excluded from the
 * window lookup to avoid self-referencing.
 */
@objc public class PointerLocationManager: NSObject {

    // Singleton instance. @objc makes it accessible from Objective-C (PointerLocation.mm).
    // `let` ensures thread-safe lazy initialization (Swift guarantees this for static lets).
    @objc public static let shared = PointerLocationManager()

    // Feature toggle flags. @objc exposes them to ObjC.
    // The didSet observer triggers updateState() whenever a flag changes,
    // which decides whether to attach or detach the overlay.
    @objc public var isShowTapsEnabled = false {
        didSet { updateState() }
    }

    @objc public var isPointerLocationEnabled = false {
        didSet { updateState() }
    }

    // The overlay window (nil when both features are disabled and overlay is detached)
    private var overlayWindow: PointerLocationOverlayWindow?
    // Guard to ensure we only swizzle UIApplication.sendEvent once.
    // Swizzling twice would undo the swizzle (swapping back to original).
    private var isSwizzled = false

    // Private init enforces singleton pattern — only `shared` can create an instance
    private override init() {
        super.init()
    }

    // These methods exist as explicit setters for ObjC compatibility.
    // In Swift you could just set the property directly, but ObjC code
    // (PointerLocation.mm) calls [manager setShowTapsEnabled:YES] which
    // needs a method, not a property setter.
    @objc public func setShowTapsEnabled(_ enabled: Bool) {
        isShowTapsEnabled = enabled
    }

    @objc public func setPointerLocationEnabled(_ enabled: Bool) {
        isPointerLocationEnabled = enabled
    }

    /**
     * Called automatically via didSet whenever either feature flag changes.
     * Decides whether the overlay should be visible and propagates feature flags
     * to the drawing view.
     */
    private func updateState() {
        let shouldBeActive = isShowTapsEnabled || isPointerLocationEnabled

        if shouldBeActive {
            attach()
        } else {
            detach()
        }

        // Propagate feature flags to the drawing view so it knows which layers to draw
        overlayWindow?.drawingView.isShowTapsEnabled = isShowTapsEnabled
        overlayWindow?.drawingView.isPointerLocationEnabled = isPointerLocationEnabled
        // Request a redraw to immediately reflect the change
        overlayWindow?.drawingView.setNeedsDisplay()
    }

    /**
     * Creates the overlay window and makes it visible.
     *
     * The window is associated with the app's UIWindowScene (required on iOS 13+).
     * connectedScenes contains all active scenes; we take the first UIWindowScene.
     * The window frame is set to the full scene bounds so it covers the entire screen.
     *
     * Setting isHidden=false makes the window visible. iOS automatically handles
     * its z-ordering based on windowLevel (set in PointerLocationOverlayWindow.setup).
     */
    private func attach() {
        // Prevent double-attach if called multiple times
        if overlayWindow != nil { return }

        // Find the active UIWindowScene. On iOS 13+ all windows belong to a scene.
        // compactMap filters out non-UIWindowScene objects and nil values.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        // Create the overlay window associated with this scene
        let window = PointerLocationOverlayWindow(windowScene: scene)
        // Set frame to match the scene's coordinate space (full screen)
        window.frame = scene.coordinateSpace.bounds
        // Make the window visible. iOS will render it above other windows
        // because its windowLevel is .statusBar + 100.
        window.isHidden = false
        overlayWindow = window

        // Install the sendEvent swizzle (if not already done)
        installSwizzle()
    }

    /**
     * Hides and releases the overlay window.
     * cleanup() on the drawing view cancels animations and clears state.
     */
    private func detach() {
        overlayWindow?.drawingView.cleanup()
        // Setting isHidden=true removes the window from the screen
        overlayWindow?.isHidden = true
        // Setting to nil releases the window and all its subviews
        overlayWindow = nil
    }

    /**
     * Swizzles UIApplication.sendEvent(_:) with our pl_sendEvent(_:).
     *
     * After this call, the method dispatch works as follows:
     * - When iOS calls [UIApplication sendEvent:], it actually runs pl_sendEvent's code
     * - When pl_sendEvent calls [self pl_sendEvent:], it actually runs the original sendEvent
     *
     * ## Why this works
     * #selector(UIApplication.sendEvent(_:)) gets the Selector for the original method.
     * #selector(UIApplication.pl_sendEvent(_:)) gets the Selector for our replacement.
     * class_getInstanceMethod looks up the Method struct (selector + implementation) for each.
     * method_exchangeImplementations swaps the IMP (implementation function pointer) between them.
     *
     * ## Why we only do this once
     * If we swizzled twice, the implementations would swap back to their original state.
     * The isSwizzled guard prevents this. We never un-swizzle because:
     * 1. Other code might have swizzled sendEvent after us (chained swizzles)
     * 2. handleEvent checks feature flags and is a no-op when disabled
     */
    private func installSwizzle() {
        guard !isSwizzled else { return }
        isSwizzled = true

        // Get Selectors (essentially method name identifiers) for both methods
        let originalSelector = #selector(UIApplication.sendEvent(_:))
        let swizzledSelector = #selector(UIApplication.pl_sendEvent(_:))

        // Look up the Method structs on the UIApplication class.
        // class_getInstanceMethod searches the class and its superclasses.
        // Returns nil if the method doesn't exist (shouldn't happen for sendEvent).
        guard let originalMethod = class_getInstanceMethod(UIApplication.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(UIApplication.self, swizzledSelector) else {
            return
        }

        // Swap the implementations. After this:
        // - The originalSelector ("sendEvent:") now points to pl_sendEvent's code
        // - The swizzledSelector ("pl_sendEvent:") now points to the original sendEvent code
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    /**
     * Called from the swizzled sendEvent (pl_sendEvent) on every UIEvent.
     *
     * Extracts all active UITouch objects from the event and forwards them to
     * the drawing view for processing and rendering.
     *
     * ## Touch coordinate resolution
     * We look up the app's "real" main window (excluding our overlay window) and pass
     * it to processTouches so touch locations are resolved in the app's coordinate space.
     * If we used the overlay window, coordinates would still be correct (same screen),
     * but this is more semantically correct and avoids any edge cases with transforms.
     */
    func handleEvent(_ event: UIEvent) {
        // Early exit if no touches in this event (could be a motion or remote-control event)
        guard let allTouches = event.allTouches, !allTouches.isEmpty else { return }
        // Early exit if both features are disabled (the swizzle stays installed but does nothing)
        guard isShowTapsEnabled || isPointerLocationEnabled else { return }

        // Find the app's main window, excluding our overlay.
        // connectedScenes → all UIWindowScenes → all windows in each → first non-overlay window.
        // This is the window where the app's views live, and where we resolve touch coordinates.
        let appWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { !($0 is PointerLocationOverlayWindow) }

        // Forward all touches to the drawing view for processing
        overlayWindow?.drawingView.processTouches(allTouches, in: appWindow)
    }
}

// MARK: - UIApplication Swizzle Extension

/**
 * Extension on UIApplication that provides the swizzled method.
 *
 * This method is added to UIApplication at compile time. Before swizzling, calling
 * pl_sendEvent would execute this code directly. After swizzling:
 *
 * 1. iOS calls sendEvent: → runs THIS code (because implementations were swapped)
 * 2. This code calls self.pl_sendEvent → runs the ORIGINAL sendEvent code
 *
 * The "recursive-looking" call to pl_sendEvent is NOT actually recursive —
 * after swizzling, pl_sendEvent's selector points to the original sendEvent implementation.
 *
 * This is the standard Objective-C swizzling pattern used throughout the iOS ecosystem.
 */
extension UIApplication {
    @objc func pl_sendEvent(_ event: UIEvent) {
        // First: let our manager process the event for drawing
        PointerLocationManager.shared.handleEvent(event)
        // Then: call the original sendEvent so the app processes the event normally.
        // This looks recursive but ISN'T — after swizzling, pl_sendEvent's implementation
        // is the original sendEvent. So this actually calls UIApplication's real sendEvent.
        pl_sendEvent(event)
    }
}
