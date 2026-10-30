'use client';

import { useMemo } from 'react';
import { useTranslations, useLocale } from 'next-intl';
import { useRouter } from 'next/navigation';
import { ChevronRight } from 'lucide-react';
import { brand } from '@oriveo/config';
import { OriveoLogo } from '@oriveo/ui';
import {
  graphemeCount,
  takeGraphemes,
} from '../../lib/utils/grapheme-utils';
import { useAppStore } from '../../providers/StoreProvider';
import { useMcpStore } from '../../lib/core/mcp/mcp-store';
import { useMcpRuntimeConfig } from '../../lib/core/mcp/use-mcp-runtime-config';
import { getVanillaStore } from '../../providers/StoreProvider';
import * as preferenceOps from '../../lib/core/preference-ops';
import type { LanguageOption, SendShortcut } from '@oriveo/shared';
import { MenuSelect } from '../../components/MenuSelect';
import { FeatureBadgeDot } from '../../components/FeatureBadgeDot';
import { FEATURE_BADGE_IDS } from '../../lib/core/feature-badges';
import { useWebSearchDefaultName } from '../../lib/search/use-web-search-entry';
import { trackEvent } from '../../lib/core/telemetry';
import { APP_VERSION } from '../../lib/version';
import { contextRowValueText } from '../../lib/core/chat/context-visibility/cap-presentation';
import { themeRowSummary } from './theme/theme-page-rules';
import { SettingsGrid, type SettingsGridItem } from './SettingsGrid';
import { SettingsIcon } from './SettingsIcons';
import styles from './Settings.module.css';

// "Follow system" is localized (see languageOptions in the component); the rest are each language's own name
const LANGUAGE_OPTIONS: { value: LanguageOption; label: string }[] = [
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
  const languageOptions = useMemo<{ value: LanguageOption; label: string }[]>(
    () => [{ value: 'system', label: t('themeSystem') }, ...LANGUAGE_OPTIONS],
    [t],
  );
  const locale = useLocale();
  const tMemory = useTranslations('pages.memory');
  const tContext = useTranslations('pages.settings.context');
  const tContextCap = useTranslations('pages.chat.contextCap');
  const tMcp = useTranslations('mcp.settings');
  const tWebSearch = useTranslations('webSearch');
  const webSearchDefaultName = useWebSearchDefaultName();
  // MCP entry: the master switch comes from the model catalog and the entry is hidden while it is off.
  // The subtitle shows how many servers there are and how many need attention.
  const mcpRuntimeConfig = useMcpRuntimeConfig();
  const mcpServerCount = useMcpStore((s) => s.servers.length);
  const mcpAttentionCount = useMcpStore((s) => s.servers.filter((server) => {
    const status = s.connections[server.id]?.status;
    return status === 'needsAuth' || status === 'unreachable' || (s.snapshots[server.id] ?? []).some((tool) => tool.pendingReview);
  }).length);
  const mcpEntrySubtitle = mcpServerCount === 0
    ? tMcp('entryHint')
    : mcpAttentionCount > 0
      ? tMcp('entryCountAttention', { count: mcpServerCount, attention: mcpAttentionCount })
      : tMcp('entryCount', { count: mcpServerCount });
  const router = useRouter();

  const preferences = useAppStore((s) => s.preferences);
  const setPreferences = useAppStore((s) => s.setPreferences);

  // Context row value = "default cap · tidy mode": the cap defaults to auto, and tidy mode defaults to off (keep the original wording only)
  const contextModeValue = contextRowValueText(preferences, locale, tContext, tContextCap);

  // Memory is often stored as a Markdown list: strip leading bullets and join lines so the preview never shows a "- "
  const trimmedMemoryText = (preferences.memoryText ?? '')
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*[-*•]\s+/, '').trim())
    .filter((line) => line.length > 0)
    .join(' ');
  const hasMemory = trimmedMemoryText.length > 0;

  const memoryPreview = hasMemory
    ? takeGraphemes(trimmedMemoryText, 30) + (graphemeCount(trimmedMemoryText) > 30 ? '...' : '')
    : tMemory('notSet');

  const aiItems: SettingsGridItem[] = [
    {
      key: 'memory',
      entry: 'memory',
      icon: <SettingsIcon name="memory" />,
      title: (
        <>
          {tMemory('settingsEntry')}
          <FeatureBadgeDot id={FEATURE_BADGE_IDS.settingsMemory} />
        </>
      ),
      value: memoryPreview,
      onSelect: () => router.push('/settings/memory'),
    },
    {
      key: 'context',
      entry: 'context',
      testId: 'settings-context-row',
      icon: <SettingsIcon name="context" />,
      title: tContext('title'),
      value: contextModeValue,
      onSelect: () => router.push('/settings/context'),
    },
    {
      key: 'skills',
      entry: 'skills',
      icon: <SettingsIcon name="skills" />,
      title: t('skills'),
      onSelect: () => router.push('/skills'),
    },
  ];

  // Tools and connections: web search + MCP servers; while the MCP master switch is off only web search is left.
  const toolItems: SettingsGridItem[] = [
    {
      key: 'webSearch',
      entry: 'webSearch',
      icon: <SettingsIcon name="search" />,
      title: (
        <>
          {tWebSearch('entry.title')}
          <FeatureBadgeDot id={FEATURE_BADGE_IDS.settingsWebSearch} />
        </>
      ),
      // No value while loading; no service configured = "Not set"
      value: webSearchDefaultName === undefined ? undefined : webSearchDefaultName ?? tWebSearch('entry.notSet'),
      onSelect: () => router.push('/settings/web-search'),
    },
    ...(mcpRuntimeConfig.enabled
      ? [{
          key: 'mcp',
          entry: 'mcp',
          icon: <SettingsIcon name="mcp" />,
          title: tMcp('entryTitle'),
          value: mcpEntrySubtitle,
          onSelect: () => router.push('/settings/mcp'),
        }]
      : []),
  ];

  const helpItems: SettingsGridItem[] = [
    {
      key: 'feedback',
      entry: 'feedback',
      icon: <SettingsIcon name="feedback" size={23} />,
      title: t('reportIssue'),
      href: `${brand.repoUrl}/issues`,
      external: true,
    },
    {
      key: 'docs',
      entry: 'docs',
      icon: <SettingsIcon name="faq" size={23} />,
      title: t('documentation'),
      href: `${brand.repoUrl}#readme`,
      external: true,
    },
  ];

  const shortcutOptions = SHORTCUT_OPTIONS.map((option) => ({
    value: option.value,
    label: t(option.labelKey),
  }));

  return (
    <div className={styles.page}>
      <h1 className={styles.title}>{t('title')}</h1>

      {/* AI: memory, context, skills (1x3) */}
      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('aiSection')}</h2>
        <SettingsGrid items={aiItems} ariaLabel={t('aiSection')} />
      </section>

      {/* Tools and connections */}
      {toolItems.length > 0 && (
        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>{t('toolsSection')}</h2>
          <SettingsGrid items={toolItems} ariaLabel={t('toolsSection')} />
        </section>
      )}

      {/* General: theme, language, send shortcut, backup */}
      <section className={styles.section}>
        <h2 className={`${styles.sectionTitle} ${styles.sectionTitleList}`}>{t('generalSection')}</h2>

        <div
          className={`${styles.listRow} ${styles.listRowNav}`}
          data-settings-entry="theme"
          onClick={() => router.push('/settings/theme')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && router.push('/settings/theme')}
        >
          <span className={styles.listIcon}><SettingsIcon name="theme" size={23} /></span>
          <span className={styles.listBody}>
            <span className={styles.listName}>{t('theme')}</span>
            <span className={styles.listValue}>
              <span className={styles.themeDot} aria-hidden="true" />
              {themeRowSummary(preferences.theme, preferences.darkPalette, t)}
            </span>
            <ChevronRight size={14} className={styles.listChevron} />
          </span>
        </div>

        <div className={styles.listRow}>
          <span className={styles.listIcon}><SettingsIcon name="language" size={23} /></span>
          <span className={styles.listBody}>
            <span className={styles.listName}>{t('language')}</span>
            <MenuSelect
              className={styles.rowControl}
              value={preferences.language}
              options={languageOptions}
              ariaLabel={t('language')}
              minWidth={176}
              menuMinWidth={220}
              onChange={(lang) => {
                preferenceOps.updateLanguage(getVanillaStore(), lang);
                // Force a Server Component refresh so the root layout re-reads the cookie and loads the matching locale
                router.refresh();
              }}
            />
          </span>
        </div>

        <div className={styles.listRow}>
          <span className={styles.listIcon}><SettingsIcon name="keyboard" size={23} /></span>
          <span className={styles.listBody}>
            <span className={styles.listName}>{t('sendShortcut')}</span>
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
          </span>
        </div>

        <div
          className={`${styles.listRow} ${styles.listRowNav}`}
          data-settings-entry="backup"
          onClick={() => router.push('/settings/backup')}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => e.key === 'Enter' && router.push('/settings/backup')}
        >
          <span className={styles.listIcon}><SettingsIcon name="backup" size={23} /></span>
          <span className={styles.listBody}>
            <span className={styles.listName}>{t('backupImportExport')}</span>
            <ChevronRight size={14} className={styles.listChevron} />
          </span>
        </div>
      </section>

      {/* Help and about (1x2) */}
      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('helpAboutSection')}</h2>
        <SettingsGrid items={helpItems} variant="compact" ariaLabel={t('helpAboutSection')} />
      </section>

      {/* Footer */}
      <footer className={styles.footer}>
        <OriveoLogo size={40} className={styles.footerLogo} />
        <div className={styles.footerName}>
          <span className={styles.footerAppName}>{brand.name}</span>
          <span className={styles.footerVersion}>{`V${APP_VERSION}`}</span>
        </div>
        <div className={styles.footerTagline}>{t('aboutTagline')}</div>
        <div className={styles.footerPoem}>{t('footerPoem')}</div>
        <div className={styles.footerLinks}>
          <a href={brand.repoUrl} target="_blank" rel="noopener noreferrer">
            {t('sourceCode')}
          </a>
        </div>
      </footer>
    </div>
  );
}
