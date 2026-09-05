'use client';

import { useSyncExternalStore } from 'react';

/**
 * Shared global subscription to whether `html[data-theme]` is dark.
 *
 * Each instance of the earlier per-component hook installed its own `MutationObserver`, and with
 * seven shortcut rail entries plus a header per group plus at least one per search result, more than
 * 30 observers could be live at once. This uses a single module-level observer and shares one
 * snapshot with every subscriber.
 */

type Listener = () => void;

const listeners = new Set<Listener>();
let isDark = false;
let observer: MutationObserver | null = null;
let mediaQuery: MediaQueryList | null = null;

function computeIsDark(): boolean {
  if (typeof document === 'undefined') return false;
  return document.documentElement.dataset.theme === 'dark';
}

function notify() {
  for (const listener of listeners) listener();
}

function ensureSubscription() {
  if (typeof document === 'undefined') return;
  if (observer) return;

  isDark = computeIsDark();

  observer = new MutationObserver(() => {
    const next = computeIsDark();
    if (next === isDark) return;
    isDark = next;
    notify();
  });
  observer.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme'],
  });

  // Also watch the system theme: while `<html data-theme>` is in system mode useTheme rewrites
  // dataset.theme after the event fires, and this keeps things in sync even when the layer above does not use useTheme
  if (window.matchMedia) {
    mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
    mediaQuery.addEventListener('change', () => {
      const next = computeIsDark();
      if (next === isDark) return;
      isDark = next;
      notify();
    });
  }
}

function subscribe(listener: Listener) {
  ensureSubscription();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    // Do not disconnect when the last subscriber leaves: a MutationObserver costs almost nothing, and this avoids attach/detach churn
  };
}

function getSnapshot(): boolean {
  return isDark;
}

function getServerSnapshot(): boolean {
  // Default to light during SSR: there is no document on the server, and the first client effect after hydration reads the real value
  return false;
}

export function useIsDarkTheme(): boolean {
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}
