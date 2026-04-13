/**
 * Native module specification for PointerLocation.
 *
 * Supports both React Native architectures:
 * - New Architecture (TurboModules): uses TurboModuleRegistry with codegen spec
 * - Old Architecture (Bridge): falls back to NativeModules lookup
 */

// TurboModuleRegistry: used by the New Architecture to look up native modules via codegen
// NativeModules: used by the Old Architecture to look up native modules via the bridge
// TurboModule: base interface that all native module specs must extend
import { TurboModuleRegistry, NativeModules, type TurboModule } from 'react-native';

/**
 * TypeScript interface defining the methods exposed by the native module.
 * On the New Architecture, this file is also used by codegen to generate
 * native bindings (Java/ObjC++ interfaces) that the native code must implement.
 */
export interface Spec extends TurboModule {
  setShowTaps(enabled: boolean): void;
  setPointerLocation(enabled: boolean): void;
}

// React Native sets global.__turboModuleProxy when TurboModules (New Arch) are enabled.
// If it exists, we can use TurboModuleRegistry; otherwise fall back to the bridge.
// @ts-ignore
const isTurboModuleEnabled = (global as any).__turboModuleProxy != null;

// Pick the right module lookup based on the architecture:
// - getEnforcing: throws if the module isn't found (New Arch, codegen-backed)
// - NativeModules.X: returns the bridge module registered with that name (Old Arch)
const PointerLocationModule = isTurboModuleEnabled
  ? TurboModuleRegistry.getEnforcing<Spec>('PointerLocation')
  : NativeModules.PointerLocation;

export default PointerLocationModule as Spec;
