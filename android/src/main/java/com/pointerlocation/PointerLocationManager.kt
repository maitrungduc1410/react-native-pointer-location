package com.pointerlocation

import android.app.Activity
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.Window
import android.widget.FrameLayout
import java.lang.ref.WeakReference

/**
 * Singleton managing the overlay view lifecycle and global touch interception on Android.
 *
 * ## Why a singleton?
 * React Native can recreate the module instance on hot reload, but we need the overlay
 * state to persist. The singleton holds the actual overlay view and touch interceptor.
 *
 * ## How the overlay works
 * We inject a [PointerLocationOverlayView] directly into the Activity's DecorView.
 * The DecorView is the top-level ViewGroup of an Activity's window — it contains the
 * status bar, the app's content view, and the navigation bar. By adding our view there
 * with MATCH_PARENT + Float.MAX_VALUE elevation, it renders above everything including
 * React Native modals, navigation headers, and toast views.
 *
 * ## How touch interception works
 * Android's Window.Callback is the first thing that receives MotionEvents before they
 * enter the view hierarchy. We wrap the Activity's existing Window.Callback using Kotlin's
 * interface delegation (`by` keyword). Only dispatchTouchEvent is overridden — it forwards
 * the event to our overlay for drawing, then calls the original callback so the app
 * processes touches normally. All other Window.Callback methods (e.g. dispatchKeyEvent,
 * onMenuItemSelected) delegate unchanged to the original.
 *
 * ## Resource management
 * - Both features disabled → overlay and interceptor are fully detached from the Activity
 * - Either feature enabled → overlay is attached and interceptor installed
 * - Activity is held via WeakReference to prevent memory leaks during configuration changes
 */
class PointerLocationManager private constructor() {

    companion object {
        // Single instance shared across all module instantiations
        val instance = PointerLocationManager()
    }

    // Feature toggle flags. Updated from PointerLocationModule on JS calls.
    // Private setters prevent external mutation — only setShowTaps/setPointerLocation
    // methods should change these so updateAttachState is always triggered.
    var isShowTapsEnabled = false
        private set
    var isPointerLocationEnabled = false
        private set

    // The overlay view currently attached to the DecorView (null when detached)
    private var overlayView: PointerLocationOverlayView? = null
    // WeakReference to the Activity avoids leaking it during config changes or
    // if React Native destroys the Activity while our singleton persists.
    private var activityRef: WeakReference<Activity>? = null
    // The Activity's original Window.Callback, saved so we can restore it on detach.
    // If we don't restore it, the wrapped callback holds a reference to our overlay
    // forever, even after the feature is disabled.
    private var originalCallback: Window.Callback? = null
    // Guard to prevent double-attaching when both features are toggled on quickly
    private var isAttached = false

    /**
     * Called from PointerLocationModule when JS calls setShowTaps(enabled).
     * Updates the flag, propagates to the overlay view, and re-evaluates
     * whether the overlay should be attached or detached.
     */
    fun setShowTaps(activity: Activity, enabled: Boolean) {
        isShowTapsEnabled = enabled
        // Propagate to the overlay view so its onDraw knows which features to render
        overlayView?.isShowTapsEnabled = enabled
        updateAttachState(activity)
    }

    /** Same as setShowTaps, but for the pointer location feature. */
    fun setPointerLocation(activity: Activity, enabled: Boolean) {
        isPointerLocationEnabled = enabled
        overlayView?.isPointerLocationEnabled = enabled
        updateAttachState(activity)
    }

    /**
     * Decides whether to attach or detach based on the combined state of both features.
     * Also triggers a redraw (invalidate) so the overlay immediately reflects the change.
     */
    private fun updateAttachState(activity: Activity) {
        val shouldBeAttached = isShowTapsEnabled || isPointerLocationEnabled
        if (shouldBeAttached && !isAttached) {
            attach(activity)
        } else if (!shouldBeAttached && isAttached) {
            detach()
        }
        // Force a redraw even if attach state didn't change (e.g. toggling one feature
        // while the other is already active)
        overlayView?.invalidate()
    }

    /**
     * Adds the overlay view to the DecorView and installs the touch interceptor.
     *
     * DecorView is the root ViewGroup of an Android Activity's window. It occupies
     * the full screen including the space behind system bars. By adding our view here
     * (instead of to the content view), we can draw over the status bar area and
     * navigation bar area as well.
     *
     * The overlay view is configured:
     * - isClickable=false, isFocusable=false → view doesn't steal touches from the app
     * - elevation=Float.MAX_VALUE → ensures our view renders above all other views
     *   (including React Native's modal overlay, navigation headers, etc.)
     */
    private fun attach(activity: Activity) {
        // Prevent double-attach if called multiple times
        if (isAttached) return

        activityRef = WeakReference(activity)

        // Create the overlay view with current feature states
        val view = PointerLocationOverlayView(activity).apply {
            isShowTapsEnabled = this@PointerLocationManager.isShowTapsEnabled
            isPointerLocationEnabled = this@PointerLocationManager.isPointerLocationEnabled
            // These two properties prevent the view from participating in touch handling.
            // Without this, the view would intercept clicks/focus and break the app.
            isClickable = false
            isFocusable = false
            // Max elevation ensures we're rendered above all other views in the DecorView.
            // Android uses elevation for z-ordering within a ViewGroup.
            elevation = Float.MAX_VALUE
        }
        overlayView = view

        // Cast to ViewGroup is safe — DecorView is always a FrameLayout subclass.
        // If it somehow fails, we bail out gracefully.
        val decorView = activity.window.decorView as? ViewGroup ?: return
        // MATCH_PARENT on both axes makes our overlay cover the entire screen
        decorView.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        // Trigger WindowInsets delivery immediately. Without this call, the view might
        // not receive insets until the next layout pass, causing the data bar to be
        // positioned incorrectly (e.g. behind the status bar) on first render.
        view.requestApplyInsets()
        // Install our MotionEvent interceptor on the Activity's window
        installTouchInterceptor(activity)
        isAttached = true
    }

    /**
     * Removes the overlay view from the DecorView and restores the original Window.Callback.
     * After detach, no resources are held — no view in the hierarchy, no callback wrapper.
     */
    private fun detach() {
        // Get the Activity (may be null if it was garbage collected or destroyed)
        val activity = activityRef?.get()

        // Remove the overlay view from its parent (the DecorView)
        overlayView?.let { view ->
            // Cancel any running animations (fading taps) and release VelocityTracker
            view.cleanup()
            // parent is the DecorView we added it to; cast and remove
            (view.parent as? ViewGroup)?.removeView(view)
        }
        overlayView = null

        // Restore the Activity's original Window.Callback so our wrapper doesn't
        // keep running (and holding references) after the feature is disabled
        restoreOriginalCallback(activity)

        activityRef = null
        isAttached = false
    }

    /**
     * Wraps the Activity's Window.Callback using Kotlin's `by` delegation.
     *
     * Kotlin's `by` keyword creates an anonymous object that implements all methods
     * of the Window.Callback interface by delegating to [delegate]. We only override
     * [dispatchTouchEvent] — all other methods (dispatchKeyEvent, onMenuItemSelected,
     * onWindowFocusChanged, etc.) are automatically forwarded to the original callback.
     *
     * dispatchTouchEvent is the very first entry point for all touch events in an Activity.
     * By intercepting here (before the event enters the view hierarchy), we see every
     * touch event regardless of which view handles it. We forward the event to our
     * overlay for drawing, then call the original implementation so the app works normally.
     *
     * Important: we extract `window.callback` into a local val `delegate` first, because
     * `window.callback` could theoretically be null if called at the wrong lifecycle moment.
     * The `?: return` bail-out prevents a crash in that edge case.
     */
    private fun installTouchInterceptor(activity: Activity) {
        val window = activity.window
        // Save the current callback so we can (a) delegate to it and (b) restore it later
        val delegate = window.callback ?: return
        originalCallback = delegate

        // Replace the window's callback with our wrapper.
        // `object : Window.Callback by delegate` creates an anonymous class that:
        //   - Implements every Window.Callback method by calling delegate.methodName()
        //   - Except dispatchTouchEvent, which we override below
        window.callback = object : Window.Callback by delegate {
            override fun dispatchTouchEvent(event: MotionEvent?): Boolean {
                // Forward the touch event to our overlay view for drawing.
                // event is nullable in the interface but practically never null.
                event?.let { overlayView?.updateTouchData(it) }
                // CRITICAL: always call the original dispatchTouchEvent.
                // This ensures the touch continues through Android's normal dispatch
                // (Activity → ViewGroup → individual Views) so the app functions normally.
                return delegate.dispatchTouchEvent(event)
            }
        }
    }

    /**
     * Restores the Activity's original Window.Callback, removing our wrapper.
     * Null-safe: handles cases where the Activity was destroyed before detach.
     */
    private fun restoreOriginalCallback(activity: Activity?) {
        if (activity != null && originalCallback != null) {
            activity.window.callback = originalCallback
        }
        originalCallback = null
    }
}
