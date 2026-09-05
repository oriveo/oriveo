/**
 *   — store + sync  
 */

import type { StoreApi } from 'zustand';
import type { ThemeOption, LanguageOption } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { getSyncAdapter } from './sync-port';
import { setLocaleCookie } from '../i18n/locale-utils';
import { trackEvent } from './telemetry';
import { graphemeCount } from '../utils/grapheme-utils';

export function updateTheme(store: StoreApi<AppStore>, theme: ThemeOption) {
  store.getState().setPreferences({ theme, themeSetByUser: true });
  getSyncAdapter()?.didUpdatePreferences({ theme });
  trackEvent('settings_changed', { key: 'theme', value: theme });
}

export function updateLanguage(store: StoreApi<AppStore>, language: LanguageOption) {
  store.getState().setPreferences({ language });
  getSyncAdapter()?.didUpdatePreferences({ language });
  setLocaleCookie(language as Parameters<typeof setLocaleCookie>[0]);
  trackEvent('settings_changed', { key: 'language', value: language });
}

export function updateMemory(
  store: StoreApi<AppStore>,
  memoryText: string | undefined,
  memoryAntiForgetEnabled: boolean | undefined,
  memoryAntiForgetText: string | undefined,
) {
  const memoryUpdatedAt = new Date().toISOString();
  //   memoryText  
  const isCleared = !memoryText?.trim();
  const previousMemory = store.getState().preferences.memoryText ?? '';
  const operation: 'clear' | 'create' | 'update' = isCleared
    ? 'clear'
    : (previousMemory ? 'update' : 'create');
  const patch = {
    memoryText: isCleared ? undefined : memoryText,
    memoryAntiForgetEnabled: isCleared ? undefined : memoryAntiForgetEnabled,
    memoryAntiForgetText: isCleared ? undefined : memoryAntiForgetText,
    memoryUpdatedAt,
  };
  store.getState().setPreferences(patch);
  getSyncAdapter()?.didUpdatePreferences(patch);
  trackEvent('memory_edited', {
    operation,
    length_graphemes: isCleared ? 0 : graphemeCount(memoryText ?? ''),
    anti_forget_enabled: Boolean(memoryAntiForgetEnabled && !isCleared),
    is_first_edit: previousMemory.length === 0 && !isCleared,
  });
}
