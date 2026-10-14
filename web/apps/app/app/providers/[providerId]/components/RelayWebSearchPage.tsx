'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { CaretRightIcon, CircleNotchIcon } from '@phosphor-icons/react';
import type { Provider } from '@oriveo/shared';
import type { RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { BackButton, Button } from '@oriveo/ui';
import { relayFamilyTransportLabel } from '../../relay/new/setup-board';
import { saveRelayWebSearchSettings } from '../../../../lib/core/provider-ops';
import { runRelayWebProbe } from '../../../../lib/core/relay-web-probe-ops';
import { withErrorReporting } from '../../../../lib/sentry/report-silent';
import { getVanillaStore } from '../../../../providers/StoreProvider';
import { relayShotSeed } from '../../../../lib/dev/relay-shots-mode';
import {
  RELAY_WEB_SEARCH_TEXT,
  relayWebDraftsFromProvider,
  relayWebFragmentsToSave,
  relayWebNextOtherChoice,
  relayWebRejectedModels,
  relayWebSearchBoard,
  relayWebTemplateNeedsConfirm,
  relayWebTemplateText,
  type RelayWebDrafts,
  type RelayWebSection,
} from '../relay-web-search-board';
import styles from '../ProviderDetail.module.css';
import boardStyles from './RelayDetailBoard.module.css';
import editStyles from './RelayEditConnection.module.css';
import setupStyles from '../../relay/new/RelaySetup.module.css';

interface RelayWebSearchPageProps {
  provider: Provider;
  /** Page header subtitle: the connection name. */
  connectionName: string;
  backLabel: string;
  onBack: () => void;
  /** After a successful save (the detail page refreshes the web row status and returns). */
  onSaved: () => void;
  disabled: boolean;
}

/**
 * Web search settings page: renders strictly from the output of relayWebSearchBoard.
 * Saving writes to local storage (an empty section = delete that section) and clears the old connection-level web fields; with unsaved changes, going back from the page first shows an unsaved-changes prompt.
 */
export function RelayWebSearchPage({ provider, connectionName, backLabel, onBack, onSaved, disabled }: RelayWebSearchPageProps) {
  const tRoot = useTranslations();
  const [baseline] = useState<RelayWebDrafts>(() => relayWebDraftsFromProvider(provider));
  // Sample preset (development builds only, always null in production): the draft applies the template, trying the Responses section first and Chat only if the template changes nothing (same as iOS).
  const [drafts, setDrafts] = useState<RelayWebDrafts>(() => {
    if (!relayShotSeed()?.detail?.webSearchTemplate) return baseline;
    const shown = relayWebSearchBoard({ provider, drafts: baseline, baseline, otherChoice: undefined }).mainSections
      .map((section) => section.transport);
    const target = (['openai_responses', 'openai_chat_completions'] as const)
      .filter((transport) => shown.includes(transport))
      .find((transport) => relayWebSearchBoard({
        provider,
        drafts: { ...baseline, [transport]: relayWebTemplateText(transport) },
        baseline,
      }).hasChanges);
    return target ? { ...baseline, [target]: relayWebTemplateText(target) } : baseline;
  });
  const [otherChoice, setOtherChoice] = useState<boolean | undefined>(undefined);
  const [templateConfirm, setTemplateConfirm] = useState<RelayWebTransport | null>(null);
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const [saving, setSaving] = useState(false);
  // Retest: only one at a time; records live in local storage, and after a run the version number is bumped to re-read the rejected area.
  const [retestingModelId, setRetestingModelId] = useState<string | null>(null);
  const [, setRecordsVersion] = useState(0);

  const board = relayWebSearchBoard({ provider, drafts, baseline, otherChoice });
  const rejectedModels = relayWebRejectedModels(provider);

  const setDraft = (transport: RelayWebTransport, value: string) => {
    setDrafts((current) => ({ ...current, [transport]: value }));
  };

  const fillTemplate = (transport: RelayWebTransport) => {
    if (relayWebTemplateNeedsConfirm(transport, drafts[transport])) setTemplateConfirm(transport);
    else setDraft(transport, relayWebTemplateText(transport));
  };

  const requestBack = () => {
    if (board.hasChanges) setShowDiscardConfirm(true);
    else onBack();
  };

  const save = async () => {
    if (!board.canSave || saving) return;
    const fragments = relayWebFragmentsToSave(drafts);
    if (!fragments) return;
    setSaving(true);
    try {
      const ok = await saveRelayWebSearchSettings(getVanillaStore(), provider, fragments);
      if (ok) onSaved();
    } finally {
      setSaving(false);
    }
  };

  // Manual retest: runs the production probe executor directly (not through the auto trigger, not added to the auto history, not counted against the cap).
  const retest = async (modelId: string) => {
    if (retestingModelId) return;
    setRetestingModelId(modelId);
    try {
      await runRelayWebProbe(getVanillaStore(), provider.id, modelId);
    } catch (error) {
      withErrorReporting('relay.web_probe_retest')(error);
    } finally {
      setRetestingModelId(null);
      setRecordsVersion((version) => version + 1);
    }
  };

  const renderSection = (section: RelayWebSection) => {
    const { transport, raw, error } = section;
    const label = relayFamilyTransportLabel(transport) ?? transport;
    const fieldId = `relay-web-${transport}`;
    return (
      <section key={transport} className={boardStyles.section} data-relay-web-transport={transport}>
        <label className={styles.relayField} htmlFor={fieldId}>{label}</label>
        {/* Section: title, then card [editor / divider / use template · clear], then error, then description. */}
        <div className={`${boardStyles.card} ${boardStyles.webCard}`}>
        <textarea
          id={fieldId}
          className={`${styles.relayTextarea} ${boardStyles.webEditor}`}
          value={raw}
          rows={5}
          dir="ltr"
          spellCheck={false}
          aria-invalid={error ? true : undefined}
          onChange={(event) => setDraft(transport, event.target.value)}
          disabled={disabled}
        />
          <div className={boardStyles.webCardActions}>
            <button
              type="button"
              className={boardStyles.textAction}
              onClick={() => fillTemplate(transport)}
              disabled={disabled}
            >
              {tRoot(RELAY_WEB_SEARCH_TEXT.useTemplate)}
            </button>
            <button
              type="button"
              className={boardStyles.textAction}
              onClick={() => setDraft(transport, '')}
              disabled={disabled || !raw}
            >
              {tRoot(RELAY_WEB_SEARCH_TEXT.clear)}
            </button>
          </div>
        </div>
        {error && (
          <p className={styles.editFieldError} role="alert">{tRoot(error.key, error.values)}</p>
        )}
        {section.showsChatNote && (
          <p className={boardStyles.statusLine}>{tRoot(RELAY_WEB_SEARCH_TEXT.chatNote)}</p>
        )}
      </section>
    );
  };

  const other = board.otherGroup;
  return (
    <div className={boardStyles.board} data-form="relay" data-relay-web-page="true">
      {/* Page header: back on the same line as title2, with a 1-line subtitle (middle truncation approximated by a single-line ellipsis). */}
      <div className={boardStyles.keysHeader} data-relay-web-header="true">
        <div className={boardStyles.keysTitleLine}>
          <BackButton className={styles.backBtn} label={backLabel} onClick={requestBack} />
          <h1 className={boardStyles.keysTitle}>{tRoot(RELAY_WEB_SEARCH_TEXT.title)}</h1>
        </div>
        <p className={`${boardStyles.statusLine} ${boardStyles.singleLine}`}>{connectionName}</p>
      </div>
      <p className={boardStyles.statusLine}>{tRoot(RELAY_WEB_SEARCH_TEXT.intro)}</p>

      {board.mainSections.map(renderSection)}

      {other && (
        <section className={boardStyles.section} data-relay-web-group="other">
          <button
            type="button"
            className={editStyles.groupToggle}
            aria-expanded={other.expanded}
            onClick={() => setOtherChoice(relayWebNextOtherChoice(other))}
          >
            <span className={boardStyles.sectionTitle}>{tRoot(RELAY_WEB_SEARCH_TEXT.otherProtocols)}</span>
            {other.trailing && (
              <span className={boardStyles.rowTrailing}>{tRoot(other.trailing.key, other.trailing.values)}</span>
            )}
            <CaretRightIcon size={14} className={editStyles.caret} data-expanded={other.expanded} aria-hidden="true" />
          </button>
          {other.expanded && other.sections.map(renderSection)}
        </section>
      )}

      {rejectedModels.length > 0 && (
        <section className={boardStyles.section} data-relay-web-rejected="true">
          <h2 className={boardStyles.sectionTitle}>{tRoot(RELAY_WEB_SEARCH_TEXT.rejectedTitle)}</h2>
          <ul className={`${boardStyles.card} ${boardStyles.webRejectedList}`}>
            {rejectedModels.map((model) => (
              <li key={model.modelId} className={boardStyles.webRejectedRow} data-relay-web-rejected-model={model.modelId}>
                <span className={`${boardStyles.rowValue} ${boardStyles.singleLine}`}>{model.name}</span>
                {retestingModelId === model.modelId ? (
                  <CircleNotchIcon
                    size={16}
                    className={`${setupStyles.spinner} ${boardStyles.webRetestSpinner}`}
                    data-relay-web-retest-running="true"
                    aria-hidden="true"
                  />
                ) : (
                  <button
                    type="button"
                    className={boardStyles.textAction}
                    onClick={() => { void retest(model.modelId); }}
                    disabled={disabled || retestingModelId !== null}
                  >
                    {tRoot(RELAY_WEB_SEARCH_TEXT.retest)}
                  </button>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      <p className={boardStyles.footnote}>{tRoot(RELAY_WEB_SEARCH_TEXT.footer)}</p>
      <p className={boardStyles.footnote} data-relay-web-probe-disclosure="true">
        {tRoot(RELAY_WEB_SEARCH_TEXT.probeDisclosure)}
      </p>

      <div className={setupStyles.actionBar} data-relay-web-action-bar="true">
        <Button
          tone="primary"
          className={setupStyles.primaryAction}
          onClick={() => { void save(); }}
          disabled={disabled || saving || !board.canSave}
        >
          {tRoot(RELAY_WEB_SEARCH_TEXT.save)}
        </Button>
      </div>

      {templateConfirm && (
        <div className={styles.confirmOverlay} onClick={() => setTemplateConfirm(null)}>
          <div
            className={styles.confirmDialog}
            role="alertdialog"
            aria-modal="true"
            aria-label={tRoot(RELAY_WEB_SEARCH_TEXT.templateReplaceTitle)}
            onClick={(event) => event.stopPropagation()}
          >
            <div className={styles.confirmTitle}>{tRoot(RELAY_WEB_SEARCH_TEXT.templateReplaceTitle)}</div>
            <div className={styles.confirmDesc}>{tRoot(RELAY_WEB_SEARCH_TEXT.templateReplaceMessage)}</div>
            <div className={styles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={() => setTemplateConfirm(null)}>
                {tRoot(RELAY_WEB_SEARCH_TEXT.cancel)}
              </Button>
              <Button
                tone="primary"
                size="sm"
                onClick={() => {
                  setDraft(templateConfirm, relayWebTemplateText(templateConfirm));
                  setTemplateConfirm(null);
                }}
              >
                {tRoot(RELAY_WEB_SEARCH_TEXT.templateReplace)}
              </Button>
            </div>
          </div>
        </div>
      )}

      {showDiscardConfirm && (
        <div className={styles.confirmOverlay} onClick={() => setShowDiscardConfirm(false)}>
          <div
            className={styles.confirmDialog}
            role="alertdialog"
            aria-modal="true"
            aria-label={tRoot(RELAY_WEB_SEARCH_TEXT.discardTitle)}
            onClick={(event) => event.stopPropagation()}
          >
            <div className={styles.confirmTitle}>{tRoot(RELAY_WEB_SEARCH_TEXT.discardTitle)}</div>
            <div className={styles.confirmDesc}>{tRoot(RELAY_WEB_SEARCH_TEXT.unsavedMessage)}</div>
            <div className={styles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={() => setShowDiscardConfirm(false)}>
                {tRoot(RELAY_WEB_SEARCH_TEXT.keepEditing)}
              </Button>
              <Button
                tone="danger"
                size="sm"
                onClick={() => {
                  setShowDiscardConfirm(false);
                  onBack();
                }}
              >
                {tRoot(RELAY_WEB_SEARCH_TEXT.discard)}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
