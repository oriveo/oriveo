'use client';

import { useId, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { XIcon } from '@phosphor-icons/react';
import type { AIModel, Provider } from '@oriveo/shared';
import { useFocusTrap } from '../../../../lib/hooks/useFocusTrap';
import { GenerationParameterPanel } from '../../../../components/generation/GenerationParameterPanel';
import styles from '../ProviderDetail.module.css';
import boardStyles from './RelayDetailBoard.module.css';

/**
 * Connection-level generation parameters (same as iOS): the same Dialog shell as the key input surface, with scrollable content;
 * a model picker on top (hidden when only 1 model is enabled), below it that model's GenerationParameterPanel; the scope is still
 * provider + model's model_default, storage unchanged.
 */
export function RelayParametersDialog({
  provider,
  models,
  initialModelID,
  onClose,
}: {
  provider: Provider;
  /** Models enabled on this connection. */
  models: AIModel[];
  initialModelID: string;
  onClose: () => void;
}) {
  const tRoot = useTranslations();
  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const selectId = useId();
  useFocusTrap(dialogRef, true);
  const [modelID, setModelID] = useState(initialModelID);
  const model = models.find((candidate) => candidate.id === modelID) ?? models[0];
  const title = tRoot('common.generationParameters');
  return (
    <div className={styles.confirmOverlay} onClick={onClose}>
      <div
        ref={dialogRef}
        className={`${styles.confirmDialog} ${boardStyles.parametersDialog}`}
        onClick={(event) => event.stopPropagation()}
        onKeyDown={(event) => {
          if (event.key === 'Escape') onClose();
        }}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        data-parameters-dialog
      >
        <div className={boardStyles.keyInputHeader} data-key-input-header>
          <button
            type="button"
            className={boardStyles.keyInputClose}
            onClick={onClose}
            aria-label={tRoot('common.close')}
            title={tRoot('common.close')}
          >
            <XIcon size={14} weight="bold" aria-hidden="true" />
          </button>
          <div id={titleId} className={boardStyles.keyInputTitle} data-key-input-title>{title}</div>
          <span aria-hidden="true" />
        </div>
        <div className={boardStyles.parametersBody} data-parameters-body>
          {models.length > 1 && (
            <div className={boardStyles.keyInputField}>
              <label className={boardStyles.keyInputLabel} htmlFor={selectId}>{tRoot('pages.relaySetup.field.model')}</label>
              <select
                id={selectId}
                className={boardStyles.keyInputBox}
                value={model?.id ?? ''}
                onChange={(event) => setModelID(event.target.value)}
              >
                {models.map((candidate) => (
                  <option key={candidate.id} value={candidate.id}>{candidate.name || candidate.id}</option>
                ))}
              </select>
            </div>
          )}
          {/* Switching model switches the panel: remounted by model key so drafts and diagnostics do not leak to another model. */}
          {model && <GenerationParameterPanel key={model.id} provider={provider} model={model} />}
        </div>
      </div>
    </div>
  );
}
