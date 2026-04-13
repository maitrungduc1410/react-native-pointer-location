package com.pointerlocation

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * React Native package registration for PointerLocation.
 *
 * Every native module needs a Package that tells React Native how to find and
 * instantiate it. This is automatically discovered via the autolinking system
 * (react-native.config.js / build.gradle).
 *
 * BaseReactPackage is the modern base class that supports both architectures.
 * The key trick: [BuildConfig.IS_NEW_ARCHITECTURE_ENABLED] (set in build.gradle)
 * tells ReactModuleInfo whether this module should be treated as a TurboModule
 * or a bridge module at runtime.
 */
class PointerLocationPackage : BaseReactPackage() {

  /**
   * Called by React Native to instantiate the module when it's first accessed.
   * The [name] parameter comes from getName() on the module, or from the JS
   * TurboModuleRegistry lookup.
   */
  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
    return if (name == PointerLocationModule.NAME) {
      PointerLocationModule(reactContext)
    } else {
      null
    }
  }

  /**
   * Provides metadata about all modules in this package.
   * React Native uses this to know which modules exist before actually creating them.
   */
  override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
    mapOf(
      PointerLocationModule.NAME to ReactModuleInfo(
        PointerLocationModule.NAME,  // name: module name as seen from JS
        PointerLocationModule.NAME,  // className: Java class name
        false,  // canOverrideExistingModule: don't allow replacing existing modules
        false,  // needsEagerInit: lazy initialization is fine
        false,  // isCxxModule: this is not a C++ module
        BuildConfig.IS_NEW_ARCHITECTURE_ENABLED  // isTurboModule: true if new arch, false if bridge
      )
    )
  }
}
