'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight, Globe, SlidersHorizontal, Trash2 } from 'lucide-react';
import type { Provider } from '@oriveo/shared';
import { BaseURLEditor } from './BaseURLEditor';
import type { OfficialEndpointCardOption } from '../../../../components/providers/OfficialEndpointSelector';
import styles from './ProviderSettingsPanel.module.css';

export type ProviderSettingsExpandedRow = 'endpoint' | null;

interface ProviderSettingsPanelProps {
  provider: Provider;
  /** Base URL save callback */
  onSaveBaseURL: (newURL: string) => void;
  /** Endpoint label ("Base URL" or "Endpoint") */
  endpointSectionLabel: string;
  /** Resolved endpoint options; an empty array means a plain base URL text input */
  endpointOptions?: OfficialEndpointCardOption[];
  endpointDescription?: string | null;
  endpointDisplayFallback?: string;
  /** Advanced Settings row tap; the row is not rendered when undefined */
  onOpenAdvanced?: () => void;
  /** Subtitle under the Advanced row; shows the transport hint in Relay mode */
  advancedSubtitle?: string;
  /** Advanced row title ("Advanced Settings" or "Edit Relay Settings") */
  advancedTitle?: string;
  /** Delete Provider row tap; the row is not rendered when undefined */
  onDelete?: () => void;
  /** Controlled expanded row - lets the parent drive the endpoint inline editor from outside */
  expandedRow?: ProviderSettingsExpandedRow;
  onExpandedRowChange?: (next: ProviderSettingsExpandedRow) => void;
}

type ExpandedRow = ProviderSettingsExpandedRow;

/**
 * Single-panel settings section.
 * - Up to three rows, as needed: Endpoint / Advanced / Delete Provider
 * - One surface with dividers between rows, and no per-row shadow
 * - Delete uses the danger text color for restrained separation
 * - Tapping the Endpoint row expands an inline editor rather than opening a modal sheet
 *
 * Changing the API key happens through the hero card at the top plus EditApiKeyDialog, not in this panel.
 */
export function ProviderSettingsPanel({
  provider,
  onSaveBaseURL,
  endpointSectionLabel,
  endpointOptions,
  endpointDescription,
  endpointDisplayFallback,
  onOpenAdvanced,
  advancedSubtitle,
  advancedTitle,
  onDelete,
  expandedRow,
  onExpandedRowChange,
}: ProviderSettingsPanelProps) {
  const t = useTranslations('pages.providerDetail');
  const tSettings = useTranslations('pages.providerDetail.settings');

  const [internalExpanded, setInternalExpanded] = useState<ExpandedRow>(null);
  const isControlled = expandedRow !== undefined;
  const expanded = isControlled ? expandedRow : internalExpanded;
  const setExpanded = (next: ExpandedRow) => {
    if (isControlled) {
      onExpandedRowChange?.(next);
    } else {
      setInternalExpanded(next);
    }
  };

  // Relay has its own endpoint editing on the Relay edit page, so the detail page hides the Endpoint row
  const showsEndpointRow = provider.kind !== 'relay';
  const showsAdvancedRow = Boolean(onOpenAdvanced);
  const showsDeleteRow = Boolean(onDelete);

  const hasAnyRow = showsEndpointRow || showsAdvancedRow || showsDeleteRow;
  if (!hasAnyRow) return null;

  const endpointValue = provider.baseURLText || endpointDisplayFallback || '—';

  return (
    <div className={styles.panel}>
      {showsEndpointRow && (
        <>
          <button
            type="button"
            className={styles.row}
            onClick={() => setExpanded(expanded === 'endpoint' ? null : 'endpoint')}
            aria-expanded={expanded === 'endpoint'}
          >
            <span className={styles.iconTile} data-tint="neutral" aria-hidden="true">
              <Globe size={14} strokeWidth={2.4} />
            </span>
            <span className={styles.copy}>
              <span className={styles.title}>{endpointSectionLabel}</span>
              <span className={styles.value}>{endpointValue}</span>
            </span>
            <ChevronRight
              className={styles.chevron}
              data-expanded={expanded === 'endpoint'}
              size={14}
              strokeWidth={2.4}
              aria-hidden="true"
            />
          </button>

          {expanded === 'endpoint' && (
            <div className={styles.rowEditor}>
              <BaseURLEditor
                currentURL={provider.baseURLText}
                displayFallback={endpointDisplayFallback}
                endpointOptions={endpointOptions}
                endpointDescription={endpointDescription}
                onSave={(newURL) => {
                  onSaveBaseURL(newURL);
                  setExpanded(null);
                }}
              />
            </div>
          )}
        </>
      )}

      {showsAdvancedRow && (
        <>
          {showsEndpointRow && <div className={styles.divider} />}
          <button
            type="button"
            className={styles.row}
            onClick={onOpenAdvanced}
          >
            <span className={styles.iconTile} data-tint="neutral" aria-hidden="true">
              <SlidersHorizontal size={14} strokeWidth={2.4} />
            </span>
            <span className={styles.copy}>
              <span className={styles.title}>{advancedTitle ?? tSettings('advanced')}</span>
              {advancedSubtitle && <span className={styles.value}>{advancedSubtitle}</span>}
            </span>
            <ChevronRight className={styles.chevron} size={14} strokeWidth={2.4} aria-hidden="true" />
          </button>
        </>
      )}

      {showsDeleteRow && (
        <>
          {(showsEndpointRow || showsAdvancedRow) && <div className={styles.divider} />}
          <button
            type="button"
            className={styles.row}
            data-tint="danger"
            onClick={onDelete}
          >
            <span className={styles.iconTile} data-tint="danger" aria-hidden="true">
              <Trash2 size={14} strokeWidth={2.4} />
            </span>
            <span className={styles.copy}>
              <span className={styles.title}>{t('deleteProvider')}</span>
            </span>
            <ChevronRight className={styles.chevron} size={14} strokeWidth={2.4} aria-hidden="true" />
          </button>
        </>
      )}
    </div>
  );
}
