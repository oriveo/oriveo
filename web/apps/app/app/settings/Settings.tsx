'use client';

import { Palette, Globe, Keyboard, Brain, Lightbulb, CloudUpload, Bug, BookOpen, ChevronRight } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { brand } from '@oriveo/config';
import { OriveoLogo } from '@oriveo/ui';
import {
  graphemeCount,
  takeGraphemes,
} from '../../lib/utils/grapheme-utils';
import { useAppStore } from '../../providers/StoreProvider';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as preferenceOps from '../../lib/core/preference-ops';
import type { ThemeOption, LanguageOption, SendShortcut } from '@oriveo/shared';
import { MenuSelect } from '../../components/MenuSelect';
import { trackEvent } from '../../lib/core/telemetry';
import { APP_VERSION } from '../../lib/version';
import styles from './Settings.module.css';

const THEME_OPTIONS: { value: ThemeOption; labelKey: string }[] = [
  { value: 'system', labelKey: 'themeSystem' },
  { value: 'light', labelKey: 'themeLight' },
  { value: 'dark', labelKey: 'themeDark' },
];

const LANGUAGE_OPTIONS: { value: LanguageOption; label: string }[] = [
  { value: 'system', label: 'System' },
  { value: 'en', label: 'English' },
  { value: 'zh-Hans', label: '简体中文' },
  { value: 'zh-Hant', label: '繁體中文' },
  { value: 'ja', label: '日本語' },
  { value: 'ko', label: '한국어' },
  { value: 'es', label: 'Español' },
  { value: 'fr', label: 'Français' },
  { value: 'de', label: 'Deutsch' },
  { value: 'pt-BR', label: 'Português (BR)' },
  { value: 'ar', label: 'العربية' },
  { value: 'hi', label: 'हिन्दी' },
  { value: 'id', label: 'Bahasa Indonesia' },
  { value: 'vi', label: 'Tiếng Việt' },
  { value: 'th', label: 'ไทย' },
  { value: 'tr', label: 'Türkçe' },
  { value: 'ru', label: 'Русский' },
];

const SHORTCUT_OPTIONS: { value: SendShortcut; labelKey: string }[] = [
  { value: 'cmdEnter', labelKey: 'shortcutCmdEnter' },
  { value: 'enter', labelKey: 'shortcutEnter' },
];

export function Settings() {
  const t = useTranslations('pages.settings');
  const tMemory = useTranslations('pages.memory');
  const router = useRouter();

  const preferences = useAppStore((s) => s.preferences);
  const setPreferences = useAppStore((s) => s.setPreferences);

  const trimmedMemoryText = preferences.memoryText?.trim() ?? '';
  const hasMemory = trimmedMemoryText.length > 0;

  const memoryPreview = hasMemory
    ? takeGraphemes(trimmedMemoryText, 30) + (graphemeCount(trimmedMemoryText) > 30 ? '...' : '')
    : tMemory('notSet');

  const themeOptions = THEME_OPTIONS.map((option) => ({
    value: option.value,
    label: t(option.labelKey),
  }));

  const shortcutOptions = SHORTCUT_OPTIONS.map((option) => ({
    value: option.value,
    label: t(option.labelKey),
  }));

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>{t('title')}</h1>
        <p className={styles.subtitle}>{t('description')}</p>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('aiSection')}</h2>

        <div
          className={styles.navRow}
          onClick={() => router.push('/settings/memory')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && router.push('/settings/memory')}
        >
          <span className={`${styles.semanticIcon} ${styles.purple}`}>
            <Brain size={16} />
          </span>
          <div className={styles.navRowInfo}>
            <div className={styles.navRowTitle}>{tMemory('settingsEntry')}</div>
            {!hasMemory && <div className={styles.navRowSubtitle}>{memoryPreview}</div>}
          </div>
          {hasMemory && (
            <div className={styles.navRowTrailing}>
              <div className={styles.navRowValue}>{memoryPreview}</div>
            </div>
          )}
          <ChevronRight size={14} className={styles.navRowChevron} />
        </div>


        <div className={styles.divider} />

        <div
          className={styles.navRow}
          onClick={() => router.push('/skills')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && router.push('/skills')}
        >
          <span className={`${styles.semanticIcon} ${styles.purple}`}>
            <Lightbulb size={16} />
          </span>
          <div className={styles.navRowInfo}>
            <div className={styles.navRowTitle}>{t('skills')}</div>
          </div>
          <ChevronRight size={14} className={styles.navRowChevron} />
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('dataSection')}</h2>
        <div
          className={styles.navRow}
          onClick={() => router.push('/settings/backup')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && router.push('/settings/backup')}
        >
          <span className={`${styles.semanticIcon} ${styles.blue}`}>
            <CloudUpload size={16} />
          </span>
          <div className={styles.navRowInfo}>
            <div className={styles.navRowTitle}>{t('backupImportExport')}</div>
          </div>
          <ChevronRight size={14} className={styles.navRowChevron} />
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('appearanceSection')}</h2>

        <div className={styles.row}>
          <span className={styles.rowLabel}>
            <span className={`${styles.semanticIcon} ${styles.amber}`}>
              <Palette size={14} />
            </span>
            {t('theme')}
          </span>
          <MenuSelect
            className={styles.rowControl}
            value={preferences.theme}
            options={themeOptions}
            ariaLabel={t('theme')}
            minWidth={156}
            onChange={(theme) => {
              preferenceOps.updateTheme(getVanillaStore(), theme);
            }}
          />
        </div>

        <div className={styles.row}>
          <span className={styles.rowLabel}>
            <span className={`${styles.semanticIcon} ${styles.amber}`}>
              <Globe size={14} />
            </span>
            {t('language')}
          </span>
          <MenuSelect
            className={styles.rowControl}
            value={preferences.language}
            options={LANGUAGE_OPTIONS}
            ariaLabel={t('language')}
            minWidth={176}
            menuMinWidth={220}
            onChange={(lang) => {
              preferenceOps.updateLanguage(getVanillaStore(), lang);
              router.refresh();
            }}
          />
        </div>

        <div className={styles.row}>
          <span className={styles.rowLabel}>
            <span className={`${styles.semanticIcon} ${styles.amber}`}>
              <Keyboard size={14} />
            </span>
            {t('sendShortcut')}
          </span>
          <MenuSelect
            className={styles.rowControl}
            value={preferences.sendShortcut}
            options={shortcutOptions}
            ariaLabel={t('sendShortcut')}
            minWidth={168}
            onChange={(sendShortcut) => {
              setPreferences({ sendShortcut });
              trackEvent('settings_changed', { key: 'send_shortcut', value: sendShortcut });
            }}
          />
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('helpSection')}</h2>

        <a
          href={`${brand.repoUrl}/issues`}
          target="_blank"
          rel="noopener noreferrer"
          className={styles.navRow}
        >
          <span className={`${styles.semanticIcon} ${styles.sky}`}>
            <Bug size={16} />
          </span>
          <div className={styles.navRowInfo}>
            <div className={styles.navRowTitle}>{t('reportIssue')}</div>
          </div>
          <ChevronRight size={14} className={styles.navRowChevron} />
        </a>

        <div className={styles.divider} />

        <a
          href={`${brand.repoUrl}#readme`}
          target="_blank"
          rel="noopener noreferrer"
          className={styles.navRow}
        >
          <span className={`${styles.semanticIcon} ${styles.indigo}`}>
            <BookOpen size={16} />
          </span>
          <div className={styles.navRowInfo}>
            <div className={styles.navRowTitle}>{t('documentation')}</div>
          </div>
          <ChevronRight size={14} className={styles.navRowChevron} />
        </a>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('aboutSection')}</h2>

        <div className={styles.aboutBrand}>
          <OriveoLogo size={44} className={styles.aboutLogo} />
          <div>
            <div className={styles.aboutAppName}>{brand.name}</div>
            <div className={styles.aboutTagline}>{t('aboutTagline')}</div>
          </div>
        </div>

        <div className={styles.divider} />

        <div className={styles.aboutInfoRow}>
          <span className={styles.aboutInfoLabel}>{t('version')}</span>
          <span className={styles.aboutInfoValue}>{`V${APP_VERSION}`}</span>
        </div>

        <div className={styles.divider} />

        <div className={styles.aboutInfoRow}>
          <span className={styles.aboutInfoLabel}>{t('privacyPolicy')}</span>
          <span className={styles.aboutInfoValue}>{t('privacySubtitle')}</span>
        </div>

        <div className={styles.divider} />

        <a
          href={brand.repoUrl}
          target="_blank"
          rel="noopener noreferrer"
          className={styles.aboutLink}
        >
          {t('sourceCode')}
          <ChevronRight size={14} className={styles.navRowChevron} />
        </a>
      </div>
    </div>
  );
}
