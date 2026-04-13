package com.pointerlocation

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule

/**
 * Old Architecture spec.
 *
 * On the old architecture there is no codegen, so we manually declare the same
 * abstract methods that the codegen would generate. This allows PointerLocationModule
 * (in src/main) to extend PointerLocationSpec regardless of which architecture is active.
 *
 * ReactContextBaseJavaModule is the base class for all bridge-based native modules.
 * It provides access to the ReactApplicationContext (and thus the current Activity).
 *
 * This file is only compiled when newArchEnabled=false (see build.gradle sourceSets).
 */
abstract class PointerLocationSpec internal constructor(context: ReactApplicationContext) :
  ReactContextBaseJavaModule(context) {

  // These signatures must match the TypeScript spec in NativePointerLocation.ts
  abstract fun setShowTaps(enabled: Boolean)
  abstract fun setPointerLocation(enabled: Boolean)
}
