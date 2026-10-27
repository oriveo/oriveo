'use client';

import { useCallback, useSyncExternalStore } from 'react';
import { lightBrandColors, resolvePaletteChoice, type LightBrand } from '@oriveo/shared';
import { tryGetVanillaStore } from '../../providers/StoreProvider';

const noopUnsubscribe = () => {};

/**
 * The current palette's brand colors in the light appearance: use it when JS needs a concrete color value (such as the input to hsbAdjusted);
 * CSS always goes through the brand variables in variables.css. The default palette = the hand-tuned defaults.
 * Outside a StoreProvider (unit tests rendering a component directly) the default palette is used.
 */
export function useLightBrandColors(): LightBrand {
  const store = tryGetVanillaStore();
  const subscribe = useCallback(
    (onChange: () => void) => (store ? store.subscribe(onChange) : noopUnsubscribe),
    [store],
  );
  const darkPalette = useSyncExternalStore(subscribe, () => store?.getState().preferences.darkPalette, () => undefined);
  const darkPaletteCustom = useSyncExternalStore(subscribe, () => store?.getState().preferences.darkPaletteCustom, () => undefined);
  return lightBrandColors(resolvePaletteChoice(darkPalette, darkPaletteCustom));
}
