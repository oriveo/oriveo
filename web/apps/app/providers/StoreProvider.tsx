'use client';

import React, {
  createContext,
  useContext,
  useMemo,
  useEffect,
  useState,
  useRef,
  useCallback,
  type ReactNode,
} from 'react';
import { useStoreWithEqualityFn } from 'zustand/traditional';
import { createAppStore, type AppStore } from '../lib/core/store/app-store';
import { subscribeToChanges } from '../lib/core/store/persistence';
import { useDarkPalette, useTheme } from '../lib/hooks/useTheme';
import { bootstrapApp, type BootstrapResult } from '../lib/core/bootstrap';
import { Skeleton } from '../components/Skeleton';
import { trackEvent } from '../lib/core/telemetry';
import { isShotsPath } from '../lib/dev/relay-shots-mode';

type Store = ReturnType<typeof createAppStore>;

const StoreContext = createContext<Store | null>(null);

let _vanillaStore: Store | null = null;

export function getVanillaStore(): Store {
  if (!_vanillaStore) throw new Error('Store not initialized');
  return _vanillaStore;
}

export function tryGetVanillaStore(): Store | null {
  return _vanillaStore;
}

interface StoreProviderProps {
  children: ReactNode;
}

const BOOTSTRAP_TIMEOUT_MS = 8000;

function ThemeSyncer() {
  const theme = useAppStore((s) => s.preferences.theme);
  const darkPalette = useAppStore((s) => s.preferences.darkPalette);
  const darkPaletteCustom = useAppStore((s) => s.preferences.darkPaletteCustom);
  useTheme(theme);
  useDarkPalette(darkPalette, darkPaletteCustom);
  return null;
}

export function StoreProvider({ children }: StoreProviderProps) {
  const store = useMemo(() => createAppStore(), []);
  _vanillaStore = store;
  const [hydrated, setHydrated] = useState(false);
  const unsubRef = useRef<(() => void) | null>(null);

  const ensureSubscribed = useCallback(() => {
    if (unsubRef.current) return;
    unsubRef.current = subscribeToChanges(store);
  }, [store]);

  useEffect(() => {
    // Screenshot routes (dev builds only): skip hydration and persistence, install the isolation fence first, then let rendering through.
    if (process.env.NODE_ENV !== 'production') {
      if (isShotsPath(window.location.pathname)) {
        const shotSignal = { cancelled: false };
        void import('../app/dev/relay-shots/relay-shots-fence').then(({ installRelayShotsFence }) => {
          if (shotSignal.cancelled) return;
          installRelayShotsFence();
          store.setState({ hydrationPhase: 'ready' });
          setHydrated(true);
        });
        return () => {
          shotSignal.cancelled = true;
        };
      }
    }
    const signal = { cancelled: false };
    const startedAt = Date.now();
    const timeoutId = globalThis.setTimeout(() => {
      if (signal.cancelled) return;
      signal.cancelled = true;
      const elapsedMs = Date.now() - startedAt;
      console.warn(`[StoreProvider] Bootstrap timed out after ${elapsedMs}ms; rendering with default state`);
      trackEvent('bootstrap_timed_out', {
        timeout_ms: BOOTSTRAP_TIMEOUT_MS,
        elapsed_ms: elapsedMs,
      });
      store.setState({ hydrationPhase: 'ready' });
      ensureSubscribed();
      setHydrated(true);
    }, BOOTSTRAP_TIMEOUT_MS);

    bootstrapApp(store, signal)
      .then((_result: BootstrapResult) => {
        if (signal.cancelled) return;
        ensureSubscribed();
      })
      .catch((err) => {
        console.error('[StoreProvider] Bootstrap failed:', err);
      })
      .finally(() => {
        if (signal.cancelled) return;
        globalThis.clearTimeout(timeoutId);
        setHydrated(true);
      });

    return () => {
      signal.cancelled = true;
      globalThis.clearTimeout(timeoutId);
      unsubRef.current?.();
    };
  }, [store, ensureSubscribed]);

  if (!hydrated) {
    return <Skeleton />;
  }

  return (
    <StoreContext.Provider value={store}>
      <ThemeSyncer />
      {children}
    </StoreContext.Provider>
  );
}

export function useAppStore<T>(selector: (state: AppStore) => T): T {
  const store = useContext(StoreContext);
  if (!store) throw new Error('useAppStore must be used within StoreProvider');
  return useStoreWithEqualityFn(store, selector, Object.is);
}
