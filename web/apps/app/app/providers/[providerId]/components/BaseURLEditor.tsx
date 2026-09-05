'use client';

import { useState, useCallback, useEffect, useMemo } from 'react';
import { useTranslations } from 'next-intl';
import { Button, EditIcon } from '@oriveo/ui';
import { OfficialEndpointSelector, type OfficialEndpointCardOption } from '../../../../components/providers/OfficialEndpointSelector';
import { resolveSelectedOfficialEndpointId } from '../../../../components/providers/official-endpoint-utils';
import styles from '../ProviderDetail.module.css';

interface BaseURLEditorProps {
  currentURL: string | undefined;
  /** Placeholder shown when nothing is set. */
  displayFallback?: string;
  placeholder?: string;
  endpointOptions?: OfficialEndpointCardOption[];
  endpointDescription?: string | null;
  onSave: (newURL: string) => void;
}

export function BaseURLEditor({
  currentURL,
  displayFallback,
  placeholder,
  endpointOptions,
  endpointDescription,
  onSave,
}: BaseURLEditorProps) {
  const t = useTranslations('pages.providerDetail');
  const tc = useTranslations('common');

  const [editing, setEditing] = useState(false);
  const [urlValue, setUrlValue] = useState('');
  const [selectedEndpointId, setSelectedEndpointId] = useState('');
  const hasEndpointOptions = (endpointOptions?.length ?? 0) > 0;
  const resolvedEndpointId = useMemo(
    () => resolveSelectedOfficialEndpointId(endpointOptions ?? [], currentURL, displayFallback),
    [currentURL, displayFallback, endpointOptions],
  );
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
    if (hasEndpointOptions) {
      const nextURL = endpointOptions?.find((option) => option.id === selectedEndpointId)?.baseURL;
      if (!nextURL) return;
      onSave(nextURL);
      setEditing(false);
      return;
    }

    onSave(urlValue);
    setEditing(false);
  }, [endpointOptions, hasEndpointOptions, onSave, selectedEndpointId, urlValue]);

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
            <div className={styles.editActions}>
              <Button tone="primary" size="sm" onClick={handleSave}>{t('saveBaseURL')}</Button>
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
                {(selectedEndpoint?.baseURL ?? currentURL ?? displayFallback ?? '-').replace(/^https?:\/\//, '')}
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
