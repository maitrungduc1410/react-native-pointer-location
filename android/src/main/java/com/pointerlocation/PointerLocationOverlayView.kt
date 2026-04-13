package com.pointerlocation

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Insets
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Build
import android.view.DisplayCutout
import kotlin.math.sqrt
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.WindowInsets
import kotlin.math.roundToInt
import androidx.core.graphics.withTranslation

/**
 * Custom View that draws all pointer location and show-taps visuals using Android Canvas API.
 *
 * This view is added to the Activity's DecorView by [PointerLocationManager] and
 * receives touch data forwarded from the manager's Window.Callback interceptor.
 * It never intercepts touches itself (isClickable=false, isFocusable=false).
 *
 * ## Drawing pipeline
 * Android calls [onDraw] whenever [invalidate] is called. We call invalidate() after
 * every touch event (from [updateTouchData]) and after fading tap animations update.
 * Each onDraw repaints all layers from scratch using the Canvas API — this is efficient
 * because Android hardware-accelerates Canvas operations and the drawing is simple geometry.
 *
 * ## Drawing Layers (painted in order, later layers render on top)
 * When pointer location is enabled:
 * 1. **Data bar** – metrics strip positioned below the safe area top inset
 * 2. **Crosshairs** – blue horizontal + vertical lines at the primary touch point
 * 3. **Touch area** – rotated ellipse from MotionEvent touchMajor/touchMinor/orientation
 * 4. **Gesture path** – velocity-colored line segments (red=slow → blue=fast) per finger
 *
 * When show taps is enabled:
 * 5. **Active taps** – white circle with dark stroke at each currently-pressed touch point
 * 6. **Fading taps** – animated circles that fade out over 200ms after finger release
 *
 * ## Coordinate system
 * Because the view fills the DecorView (full screen), coordinates from MotionEvent
 * map directly to canvas coordinates. No coordinate transformation is needed.
 */
class PointerLocationOverlayView(context: Context) : View(context) {

    // Feature flags, set by PointerLocationManager when JS toggles them.
    // onDraw checks these to decide which layers to paint.
    var isShowTapsEnabled = false
    var isPointerLocationEnabled = false

    // Screen density multiplier. All dimension constants are specified in dp
    // and multiplied by density to get actual pixel values for this device.
    private val density = resources.displayMetrics.density

    // -- Dimension constants (in dp, scaled by density) --
    // tapRadius: radius of the circle drawn at each touch point for "show taps"
    private val tapRadius = 24f * density
    // crosshairWidth: stroke width of the horizontal and vertical crosshair lines
    private val crosshairWidth = 1f * density
    // pathStrokeWidth: stroke width of the velocity-colored gesture path lines
    private val pathStrokeWidth = 2f * density
    // dataBarHeight: height of the metrics bar at the top of the screen
    private val dataBarHeight = 16f * density
    // dataBarTextSize: font size for the metrics text (matches Android's 8sp)
    private val dataBarTextSize = 8f * density
    // dataBarPadding: left padding for text within each metric column
    private val dataBarPadding = 3f * density

    // -- Safe area insets --
    // These values come from the system via WindowInsets and represent the areas
    // occupied by system UI (status bar, navigation bar, display cutout/notch).
    // We use safeInsetTop to position the data bar below the status bar/notch.
    // All four insets are tracked for potential future use with landscape orientation.
    private var safeInsetTop = 0
    private var safeInsetLeft = 0
    private var safeInsetRight = 0
    private var safeInsetBottom = 0

    init {
        // Register a listener to receive WindowInsets (safe area information).
        // This is called by the system whenever insets change (initial layout, rotation,
        // keyboard show/hide, etc.) and also when we call requestApplyInsets().
        setOnApplyWindowInsetsListener { _, insets ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // API 30+: Use the modern typed insets API.
                // systemBars() covers status bar and navigation bar.
                // displayCutout() covers notch/camera hole areas.
                // Combining them with OR gives us the full safe area.
                val systemBars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                safeInsetTop = systemBars.top
                safeInsetLeft = systemBars.left
                safeInsetRight = systemBars.right
                safeInsetBottom = systemBars.bottom
            } else {
                // Pre-API 30: Use deprecated but widely available APIs.
                // displayCutout is available from API 28; fall back to systemWindowInsets
                // for API < 28 which only has status/nav bar insets.
                @Suppress("DEPRECATION")
                val cutout = insets.displayCutout
                safeInsetTop = cutout?.safeInsetTop ?: insets.systemWindowInsetTop
                safeInsetLeft = cutout?.safeInsetLeft ?: insets.systemWindowInsetLeft
                safeInsetRight = cutout?.safeInsetRight ?: insets.systemWindowInsetRight
                safeInsetBottom = cutout?.safeInsetBottom ?: insets.systemWindowInsetBottom
            }
            // Trigger a redraw with updated inset values (data bar position may change)
            invalidate()
            // Return the insets unchanged — we're observing, not consuming them.
            // If we consumed them, other views wouldn't receive inset information.
            insets
        }
    }

    // ==================== Paint Objects ====================
    // Paint objects are reused across draw calls for performance.
    // Creating Paint objects in onDraw would cause garbage collection pressure.

    // Fill paint for active tap circles: white at 50% opacity
    private val tapFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 128   // 128/255 ≈ 50% opacity
        style = Paint.Style.FILL
    }

    // Stroke paint for active tap circles: dark gray border for visibility on light backgrounds
    private val tapStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY
        strokeWidth = 1.5f * density
        style = Paint.Style.STROKE
    }

    // Paint for the blue crosshair lines (horizontal + vertical)
    private val crosshairPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLUE
        strokeWidth = crosshairWidth
        style = Paint.Style.STROKE
    }

    // Reusable paint for gesture path segments.
    // The color is changed per-segment in drawGesturePath() before each drawLine call.
    // Round cap makes line joins look smooth at connection points.
    private val segmentPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeWidth = pathStrokeWidth
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }

    companion object {
        // Speed threshold for velocity-based path coloring.
        // This is the distance (in pixels) between two consecutive touch samples
        // that maps to the maximum speed color (blue).
        // Distances below this threshold produce colors interpolated between red and blue.
        // The value was tuned empirically to give a good visual gradient during typical gestures.
        private const val SPEED_THRESHOLD = 30f
    }

    // Data bar background: white at ~80% opacity, matching Android's native implementation
    private val dataBarBgPaint = Paint().apply {
        color = Color.WHITE
        alpha = 204 // 204/255 ≈ 80% opacity
        style = Paint.Style.FILL
    }

    // Light gray border around the data bar and between metric columns
    private val dataBarBorderPaint = Paint().apply {
        color = Color.rgb(200, 200, 200)
        strokeWidth = 1f
        style = Paint.Style.STROKE
    }

    // Red highlight paint for metric columns.
    // Used for dX/dY (full column after release) and Prs/Size (proportional fill).
    // Color matches the Android native "Pointer Location" developer option: rgb(250, 58, 51)
    private val columnRedPaint = Paint().apply {
        color = Color.rgb(250, 58, 51)
        style = Paint.Style.FILL
    }

    // Text paint for metric labels and values in the data bar
    private val dataBarTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        textSize = dataBarTextSize
        typeface = Typeface.MONOSPACE  // Monospace ensures consistent column widths
    }

    // Fill paint for the touch area ellipse: white at low opacity
    private val touchAreaFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        alpha = 80  // ~31% opacity
        style = Paint.Style.FILL
    }

    // Stroke paint for the touch area ellipse border
    private val touchAreaStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.DKGRAY
        strokeWidth = 1f * density
        style = Paint.Style.STROKE
    }

    // ==================== Data Structures ====================

    /**
     * Per-pointer state tracking all data needed for drawing and path generation.
     *
     * One instance exists per active finger (identified by MotionEvent pointer ID).
     * This is stored in [activePointers] map.
     */
    private data class PointerState(
        var x: Float = 0f,           // current X position from MotionEvent.getX(index)
        var y: Float = 0f,           // current Y position from MotionEvent.getY(index)
        var pressure: Float = 0f,    // normalized 0..1 from MotionEvent.getPressure(index)
        var size: Float = 0f,        // normalized 0..1 from MotionEvent.getSize(index)
        var touchMajor: Float = 0f,  // major axis of touch ellipse in pixels
        var touchMinor: Float = 0f,  // minor axis of touch ellipse in pixels
        var orientation: Float = 0f, // rotation angle in radians from MotionEvent.getOrientation(index)
        var isDown: Boolean = false,  // whether this pointer is currently touching the screen
        var lastPathX: Float = 0f,   // X of the previous path point (for drawing line segments)
        var lastPathY: Float = 0f,   // Y of the previous path point
        var hasPath: Boolean = false  // whether we've started drawing a path for this pointer
    )

    /**
     * Represents a tap circle that is animating its fade-out after a finger lifts.
     * The ValueAnimator drives [alpha] from 128 → 0 over 200ms.
     * When the animation ends, this is removed from [fadingTaps].
     */
    private data class FadingTap(
        val x: Float,                  // position where the finger lifted
        val y: Float,
        var alpha: Int = 128,          // current opacity (animated from 128 → 0)
        var animator: ValueAnimator? = null  // the running fade animation
    )

    /**
     * A single line segment in the gesture path.
     * Each segment connects two consecutive touch samples for one finger.
     * The [color] is interpolated based on the instantaneous speed between the two points:
     * red (Color.RED) when stationary → royal blue (65,105,225) at SPEED_THRESHOLD px distance.
     */
    private data class PathSegment(
        val x1: Float, val y1: Float,  // start point
        val x2: Float, val y2: Float,  // end point
        val color: Int                  // ARGB color computed from velocity
    )

    // ==================== Runtime State ====================

    // Map of pointer ID → state for all fingers currently touching the screen.
    // Pointer IDs are assigned by Android and are stable for the duration of a touch.
    private val activePointers = mutableMapOf<Int, PointerState>()
    // List of tap circles that are currently fading out (after finger release)
    private val fadingTaps = mutableListOf<FadingTap>()
    // Accumulated path segments for all fingers in the current gesture.
    // Cleared on ACTION_DOWN (new gesture) and on orientation change.
    private val pathSegments = mutableListOf<PathSegment>()
    // Peak number of simultaneous fingers in the current gesture.
    // Displayed as the denominator in "P: active/max".
    private var maxPointerCount = 0

    // Android's VelocityTracker computes velocities from a stream of MotionEvents.
    // We call computeCurrentVelocity(1) to get velocity in pixels/millisecond.
    // The tracker is obtained on ACTION_DOWN and recycled on ACTION_UP.
    private var velocityTracker: VelocityTracker? = null
    // Last computed velocities. These persist after finger release so the data bar
    // continues to show the final velocity (matching Android's native behavior).
    private var xVelocity = 0f
    private var yVelocity = 0f

    // Position of the primary (first) finger, used for crosshair drawing
    private var primaryX = 0f
    private var primaryY = 0f

    // Whether any finger is currently touching the screen.
    // Controls whether the data bar shows X/Y (absolute) or dX/dY (delta).
    private var isTouching = false
    // Pressure and size of the primary finger. These persist after release so the
    // data bar still shows values (with red proportional fill) when no finger is down.
    private var lastPressure = 0f
    private var lastSize = 0f
    // Gesture start/end positions for computing dX and dY after finger release.
    // startX/Y is set on ACTION_DOWN, endX/Y is set on ACTION_UP.
    private var startX = 0f
    private var startY = 0f
    private var endX = 0f
    private var endY = 0f

    // ==================== Touch Processing ====================

    /**
     * Called from [PointerLocationManager]'s Window.Callback interceptor with every MotionEvent.
     *
     * This is the main entry point for all touch data. It:
     * 1. Feeds the event into VelocityTracker for Xv/Yv computation
     * 2. Updates activePointers based on the event action
     * 3. Appends PathSegment entries for gesture path drawing
     * 4. Spawns fading tap animations on finger release
     * 5. Calls invalidate() to trigger onDraw with the updated state
     *
     * Android MotionEvent actions:
     * - ACTION_DOWN: first finger touches (always pointer index 0)
     * - ACTION_POINTER_DOWN: additional finger touches (actionIndex tells which)
     * - ACTION_MOVE: one or more fingers moved (all pointers reported)
     * - ACTION_POINTER_UP: a non-last finger lifts (actionIndex tells which)
     * - ACTION_UP: the last finger lifts (always pointer index 0)
     * - ACTION_CANCEL: gesture cancelled by the system (e.g. parent view intercept)
     */
    fun updateTouchData(event: MotionEvent) {
        // Obtain a VelocityTracker if we don't have one.
        // VelocityTracker is an Android system object that accumulates MotionEvents
        // and uses a polynomial fitting algorithm to compute smooth velocities.
        if (velocityTracker == null) {
            velocityTracker = VelocityTracker.obtain()
        }
        // Feed every event to the tracker so it can compute accurate velocities
        velocityTracker?.addMovement(event)

        // actionMasked strips the pointer index bits from the action, giving the
        // pure action type (DOWN, MOVE, UP, etc.)
        val actionMasked = event.actionMasked
        // actionIndex identifies which pointer triggered this action (only relevant
        // for POINTER_DOWN and POINTER_UP; for others it's always 0)
        val actionIndex = event.actionIndex

        when (actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // First finger down — this starts a new gesture.
                // Clear all previous state from the last gesture.
                activePointers.clear()
                pathSegments.clear()
                maxPointerCount = 1
                isTouching = true

                // Create state for the first pointer (always ID = getPointerId(0))
                val state = getOrCreatePointer(event.getPointerId(0))
                updatePointerFromEvent(state, event, 0)
                state.isDown = true
                // Capture primary finger's pressure and size for the data bar
                lastPressure = state.pressure
                lastSize = state.size
                // Record start position for dX/dY calculation after release
                startX = state.x
                startY = state.y

                // Initialize path drawing for this pointer
                if (isPointerLocationEnabled) {
                    state.lastPathX = state.x
                    state.lastPathY = state.y
                    state.hasPath = true
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                // Additional finger down — tracked independently for multi-finger paths.
                // actionIndex tells us which pointer index triggered this action.
                val pointerId = event.getPointerId(actionIndex)
                val state = getOrCreatePointer(pointerId)
                updatePointerFromEvent(state, event, actionIndex)
                state.isDown = true
                // Initialize path drawing from this finger's starting position
                if (isPointerLocationEnabled) {
                    state.lastPathX = state.x
                    state.lastPathY = state.y
                    state.hasPath = true
                }
                // Update max pointer count if we now have more simultaneous fingers than before
                if (activePointers.size > maxPointerCount) {
                    maxPointerCount = activePointers.size
                }
            }

            MotionEvent.ACTION_MOVE -> {
                // One or more fingers moved.
                // MotionEvent batches all active pointers into a single event,
                // so we iterate through all of them using event.pointerCount.
                for (i in 0 until event.pointerCount) {
                    val pointerId = event.getPointerId(i)
                    val state = getOrCreatePointer(pointerId)
                    updatePointerFromEvent(state, event, i)

                    // Append a path segment from the previous position to the current position.
                    // Color is interpolated based on the distance traveled (proxy for speed).
                    if (isPointerLocationEnabled && state.hasPath) {
                        val dx = state.x - state.lastPathX
                        val dy = state.y - state.lastPathY
                        // Euclidean distance between previous and current sample
                        val speed = sqrt(dx * dx + dy * dy)
                        // Normalize speed to 0..1 range using SPEED_THRESHOLD.
                        // t=0 (red, slow/stationary), t=1 (blue, fast)
                        val t = (speed / SPEED_THRESHOLD).coerceIn(0f, 1f)
                        // Interpolate between red and royal blue based on speed
                        val color = lerpColor(Color.RED, Color.rgb(65, 105, 225), t)
                        pathSegments.add(PathSegment(state.lastPathX, state.lastPathY, state.x, state.y, color))
                        // Advance the path drawing position for the next segment
                        state.lastPathX = state.x
                        state.lastPathY = state.y
                    }
                }
                // Update persisted values from the primary finger for the data bar
                val primary = activePointers[event.getPointerId(0)]
                if (primary != null) {
                    lastPressure = primary.pressure
                    lastSize = primary.size
                }
            }

            MotionEvent.ACTION_POINTER_UP -> {
                // A non-primary finger lifted. The primary finger is still down.
                val pointerId = event.getPointerId(actionIndex)
                val state = activePointers[pointerId]
                if (state != null) {
                    state.isDown = false
                    // Spawn a fading circle at the release position
                    if (isShowTapsEnabled) {
                        spawnFadingTap(state.x, state.y)
                    }
                    // Remove this pointer from active tracking
                    activePointers.remove(pointerId)
                }
            }

            MotionEvent.ACTION_UP -> {
                // Last finger lifted — gesture is complete.
                // Capture the end position for dX/dY calculation
                endX = event.getX(0)
                endY = event.getY(0)
                val pointerId = event.getPointerId(0)
                val state = activePointers[pointerId]
                if (state != null && isShowTapsEnabled) {
                    spawnFadingTap(endX, endY)
                }
                isTouching = false
                activePointers.clear()

                // Compute final velocity BEFORE recycling the tracker.
                // computeCurrentVelocity(1) = velocity in pixels per 1 millisecond.
                // If we recycled first, xVelocity/yVelocity would be null (defaulting to 0).
                // By computing first, we preserve the last velocity in the data bar
                // (matching Android's native behavior where velocity persists after release).
                velocityTracker?.computeCurrentVelocity(1)
                xVelocity = velocityTracker?.xVelocity ?: xVelocity
                yVelocity = velocityTracker?.yVelocity ?: yVelocity
                // Return the VelocityTracker to the system pool for reuse
                velocityTracker?.recycle()
                velocityTracker = null
            }

            MotionEvent.ACTION_CANCEL -> {
                // System cancelled the gesture (e.g. a parent ViewGroup intercepted it,
                // or a system gesture like swipe-to-go-back took over).
                // Just clean up — don't compute velocity or spawn fading taps.
                activePointers.clear()
                velocityTracker?.recycle()
                velocityTracker = null
            }
        }

        // Update live velocity while the finger is still down.
        // This runs on every MOVE event so the data bar shows real-time Xv/Yv.
        // The null check ensures we don't try to use a recycled tracker (post ACTION_UP).
        if (velocityTracker != null) {
            velocityTracker?.computeCurrentVelocity(1)
            xVelocity = velocityTracker?.xVelocity ?: 0f
            yVelocity = velocityTracker?.yVelocity ?: 0f
        }

        // Update primary finger position for crosshair drawing.
        // firstOrNull() gets the first entry in the map (the earliest-added pointer).
        val primary = activePointers.values.firstOrNull()
        if (primary != null) {
            primaryX = primary.x
            primaryY = primary.y
        }

        // Request the system to call onDraw() with the updated state
        invalidate()
    }

    /**
     * Gets an existing PointerState or creates a new one for the given pointer ID.
     * getOrPut atomically checks and inserts, avoiding duplicate state creation.
     */
    private fun getOrCreatePointer(id: Int): PointerState {
        return activePointers.getOrPut(id) { PointerState() }
    }

    /**
     * Extracts all touch properties from a MotionEvent at the given pointer index.
     *
     * Android MotionEvent stores data for all active pointers in arrays indexed by
     * "pointer index" (0 to pointerCount-1). The pointer index is NOT the same as
     * the pointer ID — the ID is stable across the touch lifetime, while the index
     * can change as fingers are added/removed.
     */
    private fun updatePointerFromEvent(state: PointerState, event: MotionEvent, index: Int) {
        state.x = event.getX(index)                   // X position in view coordinates
        state.y = event.getY(index)                   // Y position in view coordinates
        state.pressure = event.getPressure(index)      // 0..1, force-sensitive on supported hardware
        state.size = event.getSize(index)              // 0..1, normalized contact area
        state.touchMajor = event.getTouchMajor(index)  // major axis of touch ellipse in pixels
        state.touchMinor = event.getTouchMinor(index)  // minor axis of touch ellipse in pixels
        state.orientation = event.getOrientation(index) // rotation in radians, 0 = vertical
        state.isDown = true
    }

    /**
     * Creates an animated fading circle at the given position when a finger lifts.
     *
     * Uses Android's ValueAnimator to smoothly transition the alpha from 128 (semi-transparent)
     * to 0 (invisible) over 200ms. On each animation frame, the alpha is updated and
     * invalidate() is called to trigger a redraw. When the animation completes, the
     * FadingTap is removed from the list.
     */
    private fun spawnFadingTap(x: Float, y: Float) {
        val tap = FadingTap(x, y)
        fadingTaps.add(tap)

        // ValueAnimator.ofInt(128, 0) creates an animator that linearly interpolates
        // integer values from 128 down to 0. Each frame, the update listener fires.
        val animator = ValueAnimator.ofInt(128, 0).apply {
            duration = 200  // 200ms fade-out duration
            addUpdateListener { anim ->
                // Update the tap's alpha with the current animated value
                tap.alpha = anim.animatedValue as Int
                // Trigger onDraw to repaint with the new alpha
                invalidate()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) {
                    // Remove the tap from the list when fully faded out
                    fadingTaps.remove(tap)
                    invalidate()
                }
            })
        }
        tap.animator = animator
        animator.start()
    }

    // ==================== Drawing ====================

    /**
     * Main drawing method called by the Android View system.
     *
     * This is called whenever invalidate() was previously called and the system
     * is ready to render the next frame. The Canvas represents the view's drawing
     * surface (hardware-accelerated on most devices).
     *
     * Drawing order matters: later draw calls render on top of earlier ones.
     */
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // Draw pointer location layers first (data bar, crosshairs, touch area, path)
        if (isPointerLocationEnabled) {
            drawDataBar(canvas)
            drawCrosshairs(canvas)
            drawTouchArea(canvas)
            drawGesturePath(canvas)
        }

        // Draw show-taps layers on top (active circles, fading circles)
        if (isShowTapsEnabled) {
            drawActiveTaps(canvas)
            drawFadingTaps(canvas)
        }
    }

    /** Data class for a single metric column in the data bar. */
    private data class Metric(
        val label: String,          // label shown before the colon (e.g. "P", "dX", "Xv")
        val value: String,          // formatted numeric value
        val fillFraction: Float = 1f // fraction of column width filled with red (0=none, 1=full)
    )

    /**
     * Draws the metrics data bar positioned below the safe area (status bar/notch).
     *
     * Layout:
     * - The bar spans the full screen width at the safe area top position
     * - Each metric gets an equal-width column (width / numMetrics)
     * - Columns are separated by light gray vertical lines
     * - Text is left-aligned within each column with small padding
     *
     * Red background highlighting:
     * - P, Xv, Yv: never have red background (fillFraction = 0)
     * - X/dX, Y/dY: full red column ONLY after finger release (dX/dY mode)
     * - Prs: proportional red fill based on current pressure value
     * - Size: proportional red fill based on current contact size
     * Prs and Size red fills persist after finger release (values are not reset).
     *
     * Column label switching:
     * - While touching: "X" shows absolute X position, "Y" shows absolute Y position
     * - After release: "dX" shows delta from start, "dY" shows delta from start
     */
    private fun drawDataBar(canvas: Canvas) {
        // Position the bar immediately below the safe area top (below status bar/notch)
        val barTop = safeInsetTop.toFloat()
        val barBottom = barTop + dataBarHeight

        // Draw the white semi-transparent background across the full width
        canvas.drawRect(0f, barTop, width.toFloat(), barBottom, dataBarBgPaint)

        val primary = activePointers.values.firstOrNull()

        // Determine whether to show absolute position or delta based on touch state
        val xLabel: String
        val xValue: String
        val yLabel: String
        val yValue: String
        val xyFill: Float  // 0 while touching (no red), 1 after release (full red)

        if (isTouching) {
            // While touching: show absolute screen coordinates
            xLabel = "X"
            yLabel = "Y"
            xValue = "%.1f".format(primary?.x ?: 0f)
            yValue = "%.1f".format(primary?.y ?: 0f)
            xyFill = 0f  // no red highlight while actively touching
        } else {
            // After release: show delta from gesture start position
            xLabel = "dX"
            yLabel = "dY"
            xValue = "%.1f".format(endX - startX)
            yValue = "%.1f".format(endY - startY)
            xyFill = 1f  // full red background when showing deltas
        }

        // Build the list of metrics in display order.
        // fillFraction controls how much of the column width is filled with red:
        // - 0f = no red (P, Xv, Yv, and X/Y while touching)
        // - 1f = full column red (dX/dY after release)
        // - 0..1 = proportional fill (Prs, Size)
        val metrics = listOf(
            Metric("P", "${activePointers.size}/${maxPointerCount}", 0f),
            Metric(xLabel, xValue, xyFill),
            Metric(yLabel, yValue, xyFill),
            Metric("Xv", "%.3f".format(xVelocity), 0f),
            Metric("Yv", "%.3f".format(yVelocity), 0f),
            Metric("Prs", "%.2f".format(lastPressure), lastPressure.coerceIn(0f, 1f)),
            Metric("Size", "%.2f".format(lastSize), lastSize.coerceIn(0f, 1f))
        )

        // All columns get equal width — this prevents layout shift when values change
        // (e.g. going from "9.0" to "10.0" doesn't make the column wider)
        val columnWidth = width.toFloat() / metrics.size
        // Vertically center the text within the data bar height.
        // Paint.ascent() is negative (above baseline), Paint.descent() is positive (below).
        // This formula computes the Y coordinate for the text baseline to center it.
        val textY = barTop + dataBarHeight / 2f - (dataBarTextPaint.descent() + dataBarTextPaint.ascent()) / 2f

        for ((i, metric) in metrics.withIndex()) {
            val colLeft = i * columnWidth

            // Draw the red highlight background.
            // For dX/dY after release: fillFraction=1 fills the entire column.
            // For Prs/Size: fillFraction=value fills proportionally from left.
            // For P/Xv/Yv: fillFraction=0 draws nothing (zero-width rect).
            val redRight = colLeft + columnWidth * metric.fillFraction
            canvas.drawRect(colLeft, barTop, redRight, barBottom, columnRedPaint)

            // Draw vertical separator line between columns (skip the first column's left edge)
            if (i > 0) {
                canvas.drawLine(colLeft, barTop, colLeft, barBottom, dataBarBorderPaint)
            }

            // Draw the metric text (e.g. "P: 1/2", "dX: 42.0", "Xv: 0.123")
            val text = "${metric.label}: ${metric.value}"
            canvas.drawText(text, colLeft + dataBarPadding, textY, dataBarTextPaint)
        }

        // Draw the outer border rectangle around the entire data bar
        canvas.drawRect(0f, barTop, width.toFloat(), barBottom, dataBarBorderPaint)
    }

    /**
     * Draws blue crosshair lines spanning the full screen, intersecting at the primary
     * touch point. Only drawn when at least one finger is touching the screen.
     */
    private fun drawCrosshairs(canvas: Canvas) {
        if (activePointers.isEmpty()) return

        val primary = activePointers.values.firstOrNull() ?: return
        // Horizontal line: from left edge to right edge at the primary finger's Y
        canvas.drawLine(0f, primary.y, width.toFloat(), primary.y, crosshairPaint)
        // Vertical line: from top edge to bottom edge at the primary finger's X
        canvas.drawLine(primary.x, 0f, primary.x, height.toFloat(), crosshairPaint)
    }

    /**
     * Draws the physical touch contact area as a rotated ellipse for each active pointer.
     *
     * Android's MotionEvent provides:
     * - getTouchMajor(index): the length of the major axis of the touch ellipse in pixels
     * - getTouchMinor(index): the length of the minor axis in pixels
     * - getOrientation(index): the rotation angle in radians (0 = finger pointing up,
     *   PI/2 = finger pointing right)
     *
     * The ellipse is drawn by:
     * 1. Translating the canvas to the touch point (so 0,0 is the finger position)
     * 2. Rotating the canvas by the orientation angle
     * 3. Drawing an axis-aligned ellipse centered at the origin
     * This is more efficient than computing rotated ellipse points manually.
     */
    private fun drawTouchArea(canvas: Canvas) {
        for (pointer in activePointers.values) {
            if (!pointer.isDown) continue
            // Half-axes of the ellipse (touchMajor/touchMinor are full axis lengths)
            val halfMajor = pointer.touchMajor / 2f
            val halfMinor = pointer.touchMinor / 2f
            // Skip drawing if the contact area is too small to see
            if (halfMajor < 1f && halfMinor < 1f) continue

            // canvas.withTranslation is a Kotlin extension that saves the canvas state,
            // applies a translation, executes the lambda, then restores the canvas state.
            // This is equivalent to: canvas.save(); canvas.translate(x,y); ...; canvas.restore()
            canvas.withTranslation(pointer.x, pointer.y) {
              // Rotate by the finger's orientation angle (converted from radians to degrees)
              rotate(Math.toDegrees(pointer.orientation.toDouble()).toFloat())

              // Draw the ellipse centered at origin.
              // The major axis (touchMajor) maps to the Y dimension (vertical before rotation)
              // and the minor axis (touchMinor) maps to the X dimension.
              // After rotation, this matches the physical orientation of the finger.
              val oval = android.graphics.RectF(-halfMinor, -halfMajor, halfMinor, halfMajor)
              drawOval(oval, touchAreaFillPaint)   // semi-transparent white fill
              drawOval(oval, touchAreaStrokePaint)  // dark gray border

            }
        }
    }

    /**
     * Linear interpolation between two ARGB colors by factor t (0..1).
     *
     * Extracts R, G, B channels from each color, interpolates each independently,
     * and recombines into a new color. Used for velocity-based path coloring:
     * - t=0 → returns [from] (red, for slow/stationary movement)
     * - t=1 → returns [to] (blue, for fast movement)
     * - t=0.5 → returns a color halfway between red and blue
     */
    private fun lerpColor(from: Int, to: Int, t: Float): Int {
        val r = (Color.red(from) + (Color.red(to) - Color.red(from)) * t).toInt()
        val g = (Color.green(from) + (Color.green(to) - Color.green(from)) * t).toInt()
        val b = (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * t).toInt()
        return Color.rgb(r, g, b)
    }

    /**
     * Draws all accumulated gesture path segments.
     * Each segment is a short line between two consecutive touch samples,
     * colored based on the instantaneous velocity at that point.
     * This produces a gradient effect where slow movement appears red and fast movement
     * appears blue, with smooth transitions in between.
     */
    private fun drawGesturePath(canvas: Canvas) {
        for (seg in pathSegments) {
            // Set the paint color to this segment's velocity-based color
            segmentPaint.color = seg.color
            canvas.drawLine(seg.x1, seg.y1, seg.x2, seg.y2, segmentPaint)
        }
    }

    /**
     * Draws white circles with dark stroke at all currently-pressed touch points.
     * These are the "show taps" indicators — visible as long as the finger is down.
     */
    private fun drawActiveTaps(canvas: Canvas) {
        for (pointer in activePointers.values) {
            if (pointer.isDown) {
                // Reset alpha for each tap (since fading taps modify these paints too)
                tapFillPaint.alpha = 128
                tapStrokePaint.alpha = 200
                canvas.drawCircle(pointer.x, pointer.y, tapRadius, tapFillPaint)
                canvas.drawCircle(pointer.x, pointer.y, tapRadius, tapStrokePaint)
            }
        }
    }

    /**
     * Draws fading-out tap circles from recently-released fingers.
     * The alpha values are driven by ValueAnimator (see [spawnFadingTap]).
     * The stroke alpha is 1.5x the fill alpha so the border remains visible longer.
     */
    private fun drawFadingTaps(canvas: Canvas) {
        for (tap in fadingTaps) {
            tapFillPaint.alpha = tap.alpha
            // Make the stroke slightly more opaque so the border is visible even at low alpha
            tapStrokePaint.alpha = (tap.alpha * 1.5f).toInt().coerceAtMost(255)
            canvas.drawCircle(tap.x, tap.y, tapRadius, tapFillPaint)
            canvas.drawCircle(tap.x, tap.y, tapRadius, tapStrokePaint)
        }
    }

    // ==================== Lifecycle ====================

    /**
     * Called by the Android View system when the view's size changes.
     * This happens on device rotation (portrait ↔ landscape) and also on first layout.
     *
     * We clear all drawing state because:
     * - Path segments are in the old coordinate system and would look wrong
     * - Fading tap positions are in old coordinates
     * - Active pointer positions will be updated by the next touch event
     *
     * We also re-request insets because rotation may change which edges have
     * system bars (e.g. landscape may move the notch from top to left side).
     */
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        pathSegments.clear()
        // Cancel all running fade-out animations to prevent callbacks to a stale state
        for (tap in fadingTaps) { tap.animator?.cancel() }
        fadingTaps.clear()
        activePointers.clear()
        // Request new WindowInsets for the updated orientation
        requestApplyInsets()
        invalidate()
    }

    /**
     * Releases all resources. Called by [PointerLocationManager.detach] when both
     * features are disabled and the overlay is being removed from the DecorView.
     */
    fun cleanup() {
        for (tap in fadingTaps) {
            tap.animator?.cancel()
        }
        fadingTaps.clear()
        activePointers.clear()
        pathSegments.clear()
        // Return the VelocityTracker to the system pool
        velocityTracker?.recycle()
        velocityTracker = null
    }
}
