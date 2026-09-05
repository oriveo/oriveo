import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';

const LOCALES = [
  'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'de', 'pt-BR', 'ar', 'hi', 'id', 'vi', 'th', 'tr', 'ru',
] as const;

// Folder related keys in the sidebar namespace
const FOLDER_SIDEBAR_KEYS = [
  'newFolder',
  'folderNamePlaceholder',
  'emptyFolder',
  'emptyFolderHint',
  'newChatInFolder',
  'renameFolder',
  'viewFolder',
  'deleteFolder',
  'deleteFolderConfirm',
  'folderCreated',
  'folderDeleted',
  'movedToFolder',
  'movedOutOfFolder',
  'batchMovedToFolder',
  'batchMovedOut',
  'removeFromFolder',
] as const;

// Folder related keys in the contextMenu namespace
const FOLDER_CONTEXT_MENU_KEYS = [
  'moveToFolder',
] as const;

// Toast message keys (all in the sidebar namespace)
const TOAST_KEYS = [
  'folderCreated',
  'folderDeleted',
  'movedToFolder',
  'movedOutOfFolder',
  'batchMovedToFolder',
  'batchMovedOut',
] as const;

// Empty state text keys (in the sidebar namespace)
const EMPTY_STATE_KEYS = [
  'emptyFolder',
  'emptyFolderHint',
  'noConversations',
] as const;

// Delete confirmation dialog keys (in the sidebar namespace)
const DELETE_CONFIRM_KEYS = [
  'deleteFolderConfirm',
  'deleteFolder',
] as const;

// Load the JSON for every locale
const messagesDir = path.resolve(__dirname, '../../../messages');

function loadLocale(locale: string): Record<string, unknown> {
  const filePath = path.join(messagesDir, `${locale}.json`);
  const raw = fs.readFileSync(filePath, 'utf-8');
  return JSON.parse(raw);
}

function getNestedValue(obj: Record<string, unknown>, keyPath: string): unknown {
  const parts = keyPath.split('.');
  let current: unknown = obj;
  for (const part of parts) {
    if (current == null || typeof current !== 'object') return undefined;
    current = (current as Record<string, unknown>)[part];
  }
  return current;
}

// Preload the data for every locale
const localeData: Record<string, Record<string, unknown>> = {};
for (const locale of LOCALES) {
  localeData[locale] = loadLocale(locale);
}

describe('folder localization', () => {
  it('TC-24.1.1: all folder-related sidebar keys exist in ALL 16 languages', () => {
    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const key of FOLDER_SIDEBAR_KEYS) {
        const value = getNestedValue(data, `sidebar.${key}`);
        expect(value, `Missing sidebar.${key} in ${locale}`).toBeDefined();
      }
    }
  });

  it('TC-24.1.1: contextMenu.moveToFolder exists in ALL 16 languages', () => {
    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const key of FOLDER_CONTEXT_MENU_KEYS) {
        const value = getNestedValue(data, `contextMenu.${key}`);
        expect(value, `Missing contextMenu.${key} in ${locale}`).toBeDefined();
      }
    }
  });

  it('TC-24.1.2: toast messages for folder operations have translations in all languages', () => {
    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const key of TOAST_KEYS) {
        const value = getNestedValue(data, `sidebar.${key}`);
        expect(value, `Missing toast key sidebar.${key} in ${locale}`).toBeDefined();
        expect(typeof value, `Toast key sidebar.${key} in ${locale} should be string`).toBe('string');
        expect((value as string).length, `Toast key sidebar.${key} in ${locale} should be non-empty`).toBeGreaterThan(0);
      }
    }
  });

  it('TC-24.1.3: empty state texts have translations in all languages', () => {
    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const key of EMPTY_STATE_KEYS) {
        const value = getNestedValue(data, `sidebar.${key}`);
        expect(value, `Missing empty state key sidebar.${key} in ${locale}`).toBeDefined();
        expect(typeof value, `Empty state key sidebar.${key} in ${locale} should be string`).toBe('string');
        expect((value as string).length, `Empty state key sidebar.${key} in ${locale} should be non-empty`).toBeGreaterThan(0);
      }
    }
  });

  it('TC-24.1.4: delete confirmation dialog texts have translations in all languages', () => {
    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const key of DELETE_CONFIRM_KEYS) {
        const value = getNestedValue(data, `sidebar.${key}`);
        expect(value, `Missing delete confirm key sidebar.${key} in ${locale}`).toBeDefined();
        expect(typeof value, `Delete confirm key sidebar.${key} in ${locale} should be string`).toBe('string');
        expect((value as string).length, `Delete confirm key sidebar.${key} in ${locale} should be non-empty`).toBeGreaterThan(0);
      }
    }
  });

  it('TC-24.1.5: all folder-related keys are non-empty strings in all languages', () => {
    const allKeys = [
      ...FOLDER_SIDEBAR_KEYS.map((k) => `sidebar.${k}`),
      ...FOLDER_CONTEXT_MENU_KEYS.map((k) => `contextMenu.${k}`),
    ];

    for (const locale of LOCALES) {
      const data = localeData[locale];
      for (const keyPath of allKeys) {
        const value = getNestedValue(data, keyPath);
        expect(typeof value, `${keyPath} in ${locale} should be string`).toBe('string');
        expect(
          (value as string).trim().length,
          `${keyPath} in ${locale} should be non-empty after trim`,
        ).toBeGreaterThan(0);
      }
    }
  });
});
