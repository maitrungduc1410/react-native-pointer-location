import UIKit

/**
 * Non-interactive UIWindow that sits above all app content.
 *
 * ## Why a separate UIWindow? (iOS vs Android)
 * On Android, there's a single DecorView per Activity, and adding a view with max elevation
 * puts it on top. On iOS, the view hierarchy is organized into windows, each with a z-level
 * (windowLevel). To draw above everything — including modal presentations, alerts, and the
 * keyboard — we need a window with a higher windowLevel than all of those.
 *
 * .statusBar + 100 is extremely high, above:
 * - .normal (0): regular app windows
 * - .statusBar (1000): status bar
 * - .alert (2000): system alerts
 * Only system-level UI (like the screenshot flash) renders above this.
 *
 * ## Touch pass-through
 * Two mechanisms ensure touches pass through to the app:
 * 1. isUserInteractionEnabled = false: the standard UIKit property that disables hit testing
 * 2. hitTest override returning nil: belt-and-suspenders safety, explicitly returns nil
 *    even if isUserInteractionEnabled is somehow toggled
 *
 * ## Rotation and layout
 * Instead of managing layout in the window itself (which doesn't reliably receive
 * layout callbacks on rotation in modern iOS), we use an OverlayViewController as the
 * rootViewController. UIKit automatically calls viewDidLayoutSubviews on the VC
 * during rotation, which is where we resize the drawing view.
 */
class PointerLocationOverlayWindow: UIWindow {

    // The drawing view where all visuals (crosshairs, taps, paths, data bar) are painted.
    // Exposed as a public property so PointerLocationManager can:
    // - Set feature flags (isShowTapsEnabled, isPointerLocationEnabled)
    // - Forward touch data (processTouches)
    // - Trigger redraws (setNeedsDisplay)
    let drawingView = PointerLocationDrawingView()

    // UIWindow must be initialized with a windowScene on iOS 13+.
    // The scene associates the window with a display/screen configuration.
    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        setup()
    }

    // Required by NSCoding but we never create this from a storyboard/xib
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /**
     * Configures the window properties and installs the view controller.
     */
    private func setup() {
        // Set the window level extremely high so we render above everything.
        // .statusBar is 1000, so this is 1100.
        windowLevel = .statusBar + 100
        // Transparent background so the app is visible underneath
        backgroundColor = .clear
        // Disable user interaction so UIKit doesn't try to deliver touches to this window.
        // Without this, the window would intercept all touches and the app would be unresponsive.
        isUserInteractionEnabled = false
        // Start hidden; PointerLocationManager sets isHidden=false when attaching
        isHidden = true

        // Use a view controller to manage the drawing view.
        // This is important because UIViewController.viewDidLayoutSubviews is reliably
        // called during device rotation, whereas UIWindow.layoutSubviews is not always
        // called in modern iOS versions (especially with scenes).
        let vc = OverlayViewController()
        vc.drawingView = drawingView
        rootViewController = vc
    }

    /**
     * Override hitTest to always return nil, ensuring no touch is ever captured
     * by this window or any of its subviews.
     *
     * hitTest is called by UIKit's touch delivery system to find which view should
     * receive a touch event. By returning nil, we tell UIKit "nothing in this window
     * handles touches" and it moves on to the next window in the z-order (the app's window).
     *
     * This is a safety measure on top of isUserInteractionEnabled=false.
     * Some edge cases (e.g. accessibility, programmatic touch delivery) might bypass
     * isUserInteractionEnabled, but hitTest returning nil is definitive.
     */
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}

/**
 * View controller that hosts the PointerLocationDrawingView.
 *
 * The primary purpose of this VC is to receive viewDidLayoutSubviews callbacks,
 * which UIKit calls whenever the view's bounds change (including device rotation).
 * This is more reliable than overriding layoutSubviews on UIWindow.
 *
 * Private class — only used internally by PointerLocationOverlayWindow.
 */
private class OverlayViewController: UIViewController {
    // Set by PointerLocationOverlayWindow.setup() before the VC is used
    var drawingView: PointerLocationDrawingView!

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match the window's transparent appearance
        view.backgroundColor = .clear
        // Ensure the VC's root view also doesn't capture touches
        view.isUserInteractionEnabled = false
        // Add the drawing view as a subview. Its frame will be set in viewDidLayoutSubviews.
        view.addSubview(drawingView)
    }

    /**
     * Called by UIKit whenever the view's layout changes, including:
     * - Initial layout (after viewDidLoad)
     * - Device rotation (portrait ↔ landscape)
     * - Multitasking resize (iPad split view / slide over)
     * - Safe area changes (e.g. in-call status bar appearing)
     *
     * We resize the drawing view to match the VC's bounds (which match the window's bounds,
     * which match the screen). Then we trigger a redraw because the coordinate system has
     * changed (e.g. the data bar needs to be repositioned for the new safe area top).
     */
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fill the entire window with the drawing view
        drawingView.frame = view.bounds
        // Force a redraw — Core Graphics (draw(_:)) uses the new bounds/safe area
        drawingView.setNeedsDisplay()
    }
}
