package com.pointerlocation

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactMethod

/**
 * React Native native module entry point for Android.
 *
 * This is the class that React Native instantiates when JS accesses the "PointerLocation" module.
 * It extends PointerLocationSpec, which resolves to either:
 * - NativePointerLocationSpec (New Arch / TurboModule) — codegen-generated, type-safe
 * - ReactContextBaseJavaModule (Old Arch / Bridge) — manually declared abstract methods
 *
 * The build.gradle sourceSets config determines which PointerLocationSpec.kt gets compiled:
 * - newArchEnabled=true  → src/newarch/java/.../PointerLocationSpec.kt
 * - newArchEnabled=false → src/oldarch/java/.../PointerLocationSpec.kt
 *
 * All actual work is delegated to [PointerLocationManager], which manages the overlay
 * view and touch interception. Calls are dispatched to the UI thread because the manager
 * manipulates Android Views and the Activity's Window.Callback.
 */
class PointerLocationModule(reactContext: ReactApplicationContext) :
  PointerLocationSpec(reactContext) {

  // getName() tells React Native what JS name maps to this module.
  // Must match the string in TurboModuleRegistry.getEnforcing('PointerLocation')
  // and NativeModules.PointerLocation on the JS side.
  override fun getName() = NAME

  // @ReactMethod makes this method callable from JavaScript.
  // On new arch this is technically redundant (codegen handles it), but it's
  // required for old arch and harmless to include for both.
  @ReactMethod
  override fun setShowTaps(enabled: Boolean) {
    // reactApplicationContext.getCurrentActivity() returns the current foreground Activity.
    // It can be null if the app is in the background or during transitions.
    val activity = reactApplicationContext.getCurrentActivity()
    // runOnUiThread ensures we're on the main thread, which is required because
    // PointerLocationManager manipulates Views (adding to DecorView) and Window.Callback.
    activity?.runOnUiThread {
      activity.let {
          PointerLocationManager.instance.setShowTaps(it, enabled)
      }
    }
  }

  @ReactMethod
  override fun setPointerLocation(enabled: Boolean) {
    val activity = reactApplicationContext.getCurrentActivity()
    activity?.runOnUiThread {
      activity.let {
        PointerLocationManager.instance.setPointerLocation(it, enabled)
      }
    }
  }

  companion object {
    // Module name constant. Used by PointerLocationPackage for registration
    // and by getName() above.
    const val NAME = "PointerLocation"
  }
}
