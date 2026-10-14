'use client';

import { useId, useState, type SyntheticEvent } from 'react';
import { useTranslations } from 'next-intl';
import { CaretRight, CheckSquare, CircleNotch, Info, Key, MagnifyingGlass, Plus, Square, Warning } from '@phosphor-icons/react';
import { BackButton, Button, Dialog } from '@oriveo/ui';
import type { ModelBrowserGroup } from '../../[providerId]/model-browser-groups';
import type { RelayDiscoveryResult } from '../../../../lib/core/providers/probe/probe-runner';

import styles from './RelaySetup.module.css';
import { failureMessageKey } from './RelaySimpleForm';
import { relayFlagshipModelID } from './manual-setup-board';
import { ProtocolDot } from './setup-board-parts';
import type { SetupProtocol } from './setup-board';

interface RelaySetupStepTwoProps {
  host: string;
  keyCount: number;
  totalCount: number;
  query: string;
  onQueryChange: (value: string) => void;
  /** The groups (rows) under the current search; the group header count and select-all work on the whole group. */
  groups: ModelBrowserGroup[];
  fullGroups: ModelBrowserGroup[];
  selected: ReadonlySet<string>;
  isExpanded: (group: ModelBrowserGroup) => boolean;
  onToggleGroup: (group: ModelBrowserGroup, expanded: boolean) => void;
  onToggleModel: (modelID: string) => void;
  onSelectGroup: (fullGroup: ModelBrowserGroup) => void;
  protocolOf: (modelID: string) => SetupProtocol;
  keyChips: Record<string, string>;
  onAddManual: (modelID: string) => void;
  /** Opens the add input (reopening it clears the "already in the list" hint). */
  onOpenAddManual: () => void;
  /** The "already in the list, checked" hint. */
  addManualHint: boolean;
  saving: boolean;
  saveFailure: RelayDiscoveryResult | null;
  onSave: () => void;
  onBack: () => void;
}

/** Step 2 (the SetupModels board): check the models to use by group; saving verifies only the first checked one. */
export function RelaySetupStepTwo(props: RelaySetupStepTwoProps) {
  const t = useTranslations('pages.relaySetup');
  const tc = useTranslations('common');
  const [adding, setAdding] = useState(false);
  const [manualID, setManualID] = useState('');
  const manualTitleID = useId();
  const closeManual = () => {
    setManualID('');
    setAdding(false);
  };
  const subtitle = [
    props.host,
    props.keyCount >= 2 ? t('twoStep.keyCount', { count: props.keyCount }) : null,
    t('twoStep.stepOf', { current: 2, total: 2 }),
  ].filter(Boolean).join(' · ');
  const selectedCount = props.selected.size;

  const submitManual = (event: SyntheticEvent) => {
    event.preventDefault();
    const id = manualID.trim();
    if (!id) return;
    props.onAddManual(id);
    setManualID('');
    setAdding(false);
  };

  return (
    <div className={styles.modelsStep}>
      {/* Everything above the footer scrolls together; the footer (hint + Save) is pinned to the bottom of the viewport. */}
      <div className={styles.modelsScroll} data-models-scroll>
        <header className={styles.modelsHeader}>
          <BackButton
            className={styles.backButton}
            label={tc('back')}
            onClick={props.onBack}
            data-testid="relay_setup_models_back_button"
          />
          <div>
            <h1>{t('twoStep.modelsTitle')}</h1>
            <p>{subtitle}</p>
          </div>
        </header>

        {/* The search box is always shown; when there are no models an empty-state line is given below. */}
        <div className={styles.inputShell}>
          <MagnifyingGlass size={18} aria-hidden="true" />
          <input
            className={styles.shellInput}
            type="search"
            value={props.query}
            aria-label={t('twoStep.searchModels', { count: props.totalCount })}
            placeholder={t('twoStep.searchModels', { count: props.totalCount })}
            onChange={(event) => props.onQueryChange(event.target.value)}
            data-testid="relay_setup_models_search_field"
            spellCheck={false}
          />
        </div>
        {props.totalCount === 0 ? <p className={styles.modelsEmpty}>{t('twoStep.modelsEmpty')}</p> : null}

        {props.groups.map((group) => {
          const full = props.fullGroups.find((item) => item.id === group.id) ?? group;
          const groupSelected = full.models.filter((model) => props.selected.has(model.id)).length;
          const expanded = props.isExpanded(group);
          const allSelected = groupSelected === full.models.length;
          return (
            <section key={group.id} className={styles.modelGroup} data-testid="relay-setup-group" data-group-id={group.id}>
              <div className={styles.modelGroupHeader}>
                <button
                  type="button"
                  className={styles.modelGroupToggle}
                  aria-expanded={expanded}
                  onClick={() => props.onToggleGroup(group, !expanded)}
                  data-testid="relay_setup_models_group_toggle"
                >
                  <CaretRight size={12} weight="bold" className={`${styles.disclosureCaret} ${styles.modelGroupCaret}`} data-open={expanded} aria-hidden="true" />
                  <strong className={styles.modelGroupTitle}>{group.title}</strong>
                  <span className={styles.modelGroupCount}>· {full.models.length}</span>
                  {groupSelected > 0 ? (
                    <span className={styles.modelGroupSelected}>{t('twoStep.groupSelected', { count: groupSelected })}</span>
                  ) : null}
                </button>
                <button
                  type="button"
                  className={styles.pillButton}
                  disabled={allSelected}
                  onClick={() => props.onSelectGroup(full)}
                  data-testid="relay_setup_models_select_group_button"
                >
                  {t('twoStep.selectGroup')}
                </button>
              </div>
              {expanded ? (
                <ul className={styles.modelRows}>
                  {group.models.map((model) => {
                    const checked = props.selected.has(model.id);
                    const protocol = props.protocolOf(model.id);
                    const chip = checked ? props.keyChips[model.id] : undefined;
                    return (
                      <li key={model.id} data-model-row={model.id}>
                        {/* The checkbox is top-aligned; the first line is the id + protocol chip (whole line LTR), the second line the key chips. */}
                        <label className={styles.modelRow}>
                          {/* The native checkbox keeps semantics and keyboard support; visually it is swapped for a Phosphor square (duotone when checked, regular when unchecked). */}
                          <input
                            type="checkbox"
                            className={styles.visuallyHiddenCheckbox}
                            aria-label={model.id}
                            checked={checked}
                            onChange={() => props.onToggleModel(model.id)}
                            data-testid="relay_setup_models_row_toggle"
                          />
                          {checked
                            ? <CheckSquare size={24} weight="duotone" className={styles.checkboxIcon} data-checked="true" aria-hidden="true" />
                            : <Square size={24} className={styles.checkboxIcon} aria-hidden="true" />}
                          <span className={styles.modelRowText}>
                            <span className={styles.modelRowLine} dir="ltr">
                              <span className={styles.modelRowID}>{model.id}</span>
                              <span className={`${styles.valueChip} ${styles.modelProtocolChip}`}><ProtocolDot protocol={protocol} />{protocol}</span>
                            </span>
                            {chip ? (
                              <span className={`${styles.keyChip} ${styles.modelKeyChip}`} data-testid="relay-setup-key-chip"><Key size={12} aria-hidden="true" />{chip}</span>
                            ) : null}
                          </span>
                        </label>
                      </li>
                    );
                  })}
                </ul>
              ) : null}
            </section>
          );
        })}

        <button
          type="button"
          className={`${styles.linkButton} ${styles.addManualButton}`}
          onClick={() => {
            props.onOpenAddManual();
            setAdding(true);
          }}
          data-testid="relay_setup_models_add_manual_button"
        >
          <Plus size={16} aria-hidden="true" />
          <span>{t('twoStep.addModelManually')}</span>
        </button>
        {/* Manual add is a dialog (title, input, Cancel + Add), replacing the earlier inline input. */}
        <Dialog open={adding} onClose={closeManual} ariaLabelledBy={manualTitleID} initialFocusSelector="input">
          <form className={styles.manualModelDialog} onSubmit={submitManual}>
            <h2 id={manualTitleID} className={styles.manualModelDialogTitle}>{t('twoStep.addModelManually')}</h2>
            <input
              className={styles.input}
              aria-labelledby={manualTitleID}
              placeholder={relayFlagshipModelID()}
              value={manualID}
              onChange={(event) => setManualID(event.target.value)}
              autoComplete="off"
              spellCheck={false}
            />
            <div className={styles.manualModelDialogActions}>
              <Button type="button" tone="secondary" size="sm" onClick={closeManual}>
                {tc('cancel')}
              </Button>
              <Button
                type="button"
                tone="primary"
                size="sm"
                onClick={submitManual}
                disabled={!manualID.trim()}
                data-testid="relay_setup_models_add_manual_confirm_button"
              >
                {tc('add')}
              </Button>
            </div>
          </form>
        </Dialog>
        {props.addManualHint ? (
          <p className={styles.addManualHint} role="status" data-testid="relay_setup_models_add_manual_hint">
            {t('twoStep.alreadyInList')}
          </p>
        ) : null}

        {/* Verification failed before persisting: a warning icon plus one-line reason, with no title / technical details / retry count. */}
        {props.saveFailure ? (
          <p className={styles.saveFailure} role="status" data-state="error">
            <Warning size={16} weight="duotone" aria-hidden="true" />
            <span>{t(failureMessageKey(props.saveFailure.failure))}</span>
          </p>
        ) : null}
      </div>

      <div className={styles.actionBar}>
        <p className={styles.saveNote}><Info size={16} aria-hidden="true" />{t('twoStep.saveNote')}</p>
        <Button
          className={styles.primaryAction}
          onClick={props.onSave}
          disabled={selectedCount === 0 || props.saving}
          data-testid="relay_setup_models_save_button"
        >
          {props.saving ? <CircleNotch className={styles.spinner} size={18} data-spinner aria-hidden="true" /> : null}
          <span>{t('twoStep.saveSelected', { count: selectedCount })}</span>
        </Button>
      </div>
    </div>
  );
}
