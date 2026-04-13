/**
 * Objective-C++ bridge between React Native and the Swift PointerLocationManager.
 *
 * This file uses the .mm extension (Objective-C++) because the New Architecture's
 * TurboModule system requires C++ for getTurboModule: (it returns a std::shared_ptr).
 * The Old Architecture code is pure Objective-C but sharing the .mm file is harmless.
 *
 * Both architectures dispatch calls to PointerLocationManager.shared on the main queue,
 * since all UI operations (overlay window, drawing) must happen on the main thread.
 * React Native may call native module methods from a background thread.
 *
 * ## Swift interop
 * The Swift header import uses __has_include to handle both CocoaPods configurations:
 * - Static frameworks (use_frameworks! :static): header is "PointerLocation-Swift.h"
 *   (flat header search path, file lives alongside other headers)
 * - Dynamic frameworks: header is <PointerLocation/PointerLocation-Swift.h>
 *   (namespaced within the framework bundle)
 * This auto-generated header exposes Swift classes/methods marked with @objc to Objective-C.
 */

// ============================================================
// NEW ARCHITECTURE: TurboModule
// ============================================================
#ifdef RCT_NEW_ARCH_ENABLED

// Import our own header which declares the NativePointerLocationSpec conformance
#import "PointerLocation.h"

// Import the auto-generated Swift→ObjC bridging header.
// This makes PointerLocationManager (a Swift class marked @objc) visible to ObjC code.
#if __has_include("PointerLocation-Swift.h")
#import "PointerLocation-Swift.h"
#else
#import <PointerLocation/PointerLocation-Swift.h>
#endif

@implementation PointerLocation

// Called from JS: PointerLocation.setShowTaps(true/false)
// dispatch_async to main queue because PointerLocationManager manipulates UIWindow
// and UIView objects which must only be touched from the main thread.
- (void)setShowTaps:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PointerLocationManager shared] setShowTapsEnabled:enabled];
    });
}

// Called from JS: PointerLocation.setPointerLocation(true/false)
- (void)setPointerLocation:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PointerLocationManager shared] setPointerLocationEnabled:enabled];
    });
}

// Required by TurboModule system. Returns a C++ TurboModule object that the JS
// engine uses to call native methods directly (without going through the bridge).
// NativePointerLocationSpecJSI is codegen-generated from NativePointerLocation.ts.
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativePointerLocationSpecJSI>(params);
}

// The module name that JS uses to look up this module.
// Must match TurboModuleRegistry.getEnforcing('PointerLocation') in NativePointerLocation.ts.
+ (NSString *)moduleName
{
    return @"PointerLocation";
}

@end

// ============================================================
// OLD ARCHITECTURE: Bridge Module
// ============================================================
#else

// RCTBridgeModule.h provides the protocol and macros for old-architecture bridge modules
#import <React/RCTBridgeModule.h>

// Same Swift bridging header import as above
#if __has_include("PointerLocation-Swift.h")
#import "PointerLocation-Swift.h"
#else
#import <PointerLocation/PointerLocation-Swift.h>
#endif

// On old architecture, the @interface is declared inline here (not in a .h file)
// because the .h file is wrapped in #ifdef RCT_NEW_ARCH_ENABLED.
@interface PointerLocation : NSObject <RCTBridgeModule>
@end

@implementation PointerLocation

// RCT_EXPORT_MODULE() registers this class as a native module with React Native's bridge.
// Without arguments, it uses the class name "PointerLocation" as the module name.
RCT_EXPORT_MODULE()

// Return NO because we handle main queue dispatch ourselves in each method.
// If we returned YES, React Native would create the module instance on the main queue,
// but our methods would still be called on the RN bridge thread.
+ (BOOL)requiresMainQueueSetup {
    return NO;
}

// RCT_EXPORT_METHOD makes this method callable from JavaScript via the bridge.
// The method signature is parsed by React Native to determine argument types.
RCT_EXPORT_METHOD(setShowTaps:(BOOL)enabled) {
    // Same main-queue dispatch as the new architecture version
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PointerLocationManager shared] setShowTapsEnabled:enabled];
    });
}

RCT_EXPORT_METHOD(setPointerLocation:(BOOL)enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PointerLocationManager shared] setPointerLocationEnabled:enabled];
    });
}

@end

#endif
