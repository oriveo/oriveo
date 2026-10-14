'use client';

import { useState, useCallback, useEffect, useMemo } from 'react';
import { useTranslations } from 'next-intl';
import { Button, EditIcon } from '@oriveo/ui';
import { OfficialEndpointSelector, type OfficialEndpointCardOption } from '../../../../components/providers/OfficialEndpointSelector';
import { resolveSelectedOfficialEndpointId } from '../../../../components/providers/official-endpoint-utils';
import type { Provider } from '@oriveo/shared';
import {
  templatePlaceholderIds,
  type OfficialEndpointConfig,
  type SetupValues,
} from '@oriveo/core/providers/transport/endpoint-resolver';
import { buildOfficialSetupEndpoint } from '../../../../lib/core/providers/endpoint-source';
import styles from '../ProviderDetail.module.css';

interface BaseURLEditorProps {
  currentURL: string | undefined;
  /** Placeholder shown when nothing is set. */
  displayFallback?: string;
  placeholder?: string;
  endpointOptions?: OfficialEndpointCardOption[];
  endpointDescription?: string | null;
  onSave: (newURL: string) => void;
  /** Official provider with setup fields: template regions are listed as-is, selecting one shows a Workspace ID slot, and the address is computed by the same function as above. */
  setupConfig?: { kind: string; config: OfficialEndpointConfig | null };
  storedEndpointSource?: string;
  storedSetupValues?: SetupValues;
  /** Save a selected template region: address, region source and setupValues are written at once. */
  onSaveEndpoint?: (endpoint: Pick<Provider, 'baseURLText' | 'endpointSource' | 'setupValues'>) => void;
}

export function BaseURLEditor({
  currentURL,
  displayFallback,
  placeholder,
  endpointOptions,
  endpointDescription,
  onSave,
  setupConfig,
  storedEndpointSource,
  storedSetupValues,
  onSaveEndpoint,
}: BaseURLEditorProps) {
  const t = useTranslations('pages.providerDetail');
  const tSetup = useTranslations('pages.providerSetup');
  const tc = useTranslations('common');
  const [setupValues, setSetupValues] = useState<SetupValues>({});

  const [editing, setEditing] = useState(false);
  const [urlValue, setUrlValue] = useState('');
  const [selectedEndpointId, setSelectedEndpointId] = useState('');
  const hasEndpointOptions = (endpointOptions?.length ?? 0) > 0;
  const resolvedEndpointId = useMemo(() => {
    // The template region's literal address does not match the template; identify it by the stored region source.
    const storedRegionID = storedEndpointSource?.startsWith('region:') ? storedEndpointSource.slice(7) : null;
    const storedTemplate = endpointOptions?.find((option) => (
      option.id === storedRegionID && templatePlaceholderIds(option.baseURL).length > 0
    ));
    return storedTemplate?.id
      ?? resolveSelectedOfficialEndpointId(endpointOptions ?? [], currentURL, displayFallback, storedEndpointSource);
  }, [currentURL, displayFallback, endpointOptions, storedEndpointSource]);
  const setupEndpoint = useMemo(() => (
    setupConfig && hasEndpointOptions
      ? buildOfficialSetupEndpoint({
        kind: setupConfig.kind,
        config: { ...(setupConfig.config ?? {}), regionOptions: endpointOptions ?? [] },
        regionId: selectedEndpointId,
        values: setupValues,
      })
      : null
  ), [endpointOptions, hasEndpointOptions, selectedEndpointId, setupConfig, setupValues]);
  const needsSetupFields = (setupEndpoint?.fields.length ?? 0) > 0;
  const selectedEndpoint = useMemo(
    () => endpointOptions?.find((option) => option.id === resolvedEndpointId) ?? null,
    [endpointOptions, resolvedEndpointId],
  );

  useEffect(() => {
    setUrlValue(currentURL ?? '');
    if (hasEndpointOptions) {
      setSelectedEndpointId(resolvedEndpointId);
    }
  }, [currentURL, hasEndpointOptions, resolvedEndpointId]);

  const handleSave = useCallback(() => {
    if (needsSetupFields) {
      if (!setupEndpoint?.result || !onSaveEndpoint) return;
      onSaveEndpoint(setupEndpoint.result);
      setEditing(false);
      return;
    }
    if (hasEndpointOptions) {
      const nextURL = endpointOptions?.find((option) => option.id === selectedEndpointId)?.baseURL;
      if (!nextURL) return;
      onSave(nextURL);
      setEditing(false);
      return;
    }

    onSave(urlValue);
    setEditing(false);
  }, [endpointOptions, hasEndpointOptions, needsSetupFields, onSave, onSaveEndpoint, selectedEndpointId, setupEndpoint, urlValue]);

  return (
    <div className={styles.keyRow}>
      {editing ? (
        hasEndpointOptions ? (
          <div className={styles.editStack}>
            <OfficialEndpointSelector
              description={endpointDescription}
              options={endpointOptions ?? []}
              value={selectedEndpointId}
              onChange={setSelectedEndpointId}
            />
            {setupEndpoint?.fields.includes('workspaceId') && (
              <label className={styles.editStack}>
                <span>{tSetup('workspaceId')}</span>
                <input
                  type="text"
                  className={styles.editInput}
                  aria-label={tSetup('workspaceId')}
                  value={setupValues.workspaceId ?? ''}
                  onChange={(e) => {
                    const workspaceId = e.target.value;
                    setSetupValues((prev) => ({ ...prev, workspaceId }));
                  }}
                  autoCapitalize="off"
                  autoCorrect="off"
                  autoComplete="off"
                  spellCheck={false}
                />
                <small>{tSetup('workspaceIdHint')}</small>
              </label>
            )}
            <div className={styles.editActions}>
              <Button
                tone="primary"
                size="sm"
                onClick={handleSave}
                disabled={needsSetupFields && !setupEndpoint?.result}
              >
                {t('saveBaseURL')}
              </Button>
              <Button tone="secondary" size="sm" onClick={() => setEditing(false)}>{tc('cancel')}</Button>
            </div>
          </div>
        ) : (
          <div className={styles.editRow}>
            <div className={styles.editInputWrap}>
              <input
                type="text"
                className={styles.editInput}
                value={urlValue}
                onChange={(e) => setUrlValue(e.target.value)}
                placeholder={placeholder ?? 'https://api.example.com/v1'}
                autoCapitalize="off"
                autoCorrect="off"
                autoComplete="off"
                spellCheck={false}
                inputMode="url"
              />
            </div>
            <Button tone="primary" size="sm" onClick={handleSave}>{t('saveBaseURL')}</Button>
            <Button tone="secondary" size="sm" onClick={() => setEditing(false)}>{tc('cancel')}</Button>
          </div>
        )
      ) : (
        <div className={styles.keyDisplay}>
          {hasEndpointOptions ? (
            <div className={styles.endpointSummary}>
              <span className={styles.endpointName}>
                {selectedEndpoint?.label ?? currentURL ?? displayFallback ?? '-'}
              </span>
              <span className={styles.endpointURL}>
                {(selectedEndpoint && templatePlaceholderIds(selectedEndpoint.baseURL).length === 0
                  ? selectedEndpoint.baseURL
                  : currentURL ?? displayFallback ?? '-').replace(/^https?:\/\//, '')}
              </span>
            </div>
          ) : (
            <span className={styles.keyText}>
              {currentURL || displayFallback || '-'}
            </span>
          )}
          <button
            className={styles.iconBtn}
            onClick={() => {
              setUrlValue(currentURL ?? '');
              setSelectedEndpointId(resolvedEndpointId);
              setSetupValues({ ...(storedSetupValues ?? {}) });
              setEditing(true);
            }}
            aria-label={t('editBaseURL')}
          >
            <EditIcon />
          </button>
        </div>
      )}
    </div>
  );
}
