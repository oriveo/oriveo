import { getLibraryRuntimeConfig } from "../metadata/metadata-client";
import { isLibraryEnabledByServer } from "./types";

// Both switches must pass:
// - the build flag, which says whether this build has a document source wired up at all;
// - the value in the model catalog, so a source that goes away stops being offered instead of
//   producing an entry point that fails the moment the user taps it.
export function isLibraryFeatureEnabled(): boolean {
  if (!isLibraryBuildEnabled()) return false;
  return isLibraryEnabledByServer(getLibraryRuntimeConfig());
}

/**
 * The build half on its own, opt-in: without a document-source connector every Library entry point
 * would lead to a request that cannot succeed.
 *
 * It is exposed separately because it is the one half a routing decision can trust immediately.
 * Being off here is locally certain and no catalog snapshot can change it, whereas a catalog that
 * reports the source as unavailable may simply be stale.
 */
export function isLibraryBuildEnabled(): boolean {
  return process.env.NEXT_PUBLIC_LIBRARY_ENABLED === "true";
}
