'use client';

import { useId, useState, type Dispatch, type MouseEventHandler, type SetStateAction } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  ArrowsClockwiseIcon,
  CaretRightIcon,
  CheckCircleIcon,
  CircleNotchIcon,
  PencilSimpleIcon,
  PlusIcon,
  TrashIcon,
  WarningIcon,
  type Icon,
} from '@phosphor-icons/react';
import type { Provider } from '@oriveo/shared';
import type { RelayKeyOp } from '@oriveo/shared/relay/relay-keys';
import { BackButton, Button } from '@oriveo/ui';
import { applyRelayKeyOperation } from '../../../../lib/core/relay-model-probe-ops';
import { relayProviderRequiresCredential } from '../../../../lib/core/providers/relay-runtime-support';
import { getVanillaStore } from '../../../../providers/StoreProvider';
import { relayShotSeed } from '../../../../lib/dev/relay-shots-mode';
import { formatCompactRelativeTime } from '../../../../lib/utils/format-utils';
import {
  relayKeyInputSheet,
  relayKeyNoticeView,
  relayKeysBoard,
  type KeyText,
  type RelayKeyInputField,
  type RelayKeyNotice,
  type RelayKeyStatusMark,
  type RelayKeysPageRow,
} from '../relay-keys-board';
import {
  beginRelayKeyOp,
  finishRelayKeyOp,
  relayKeyOpFetchingIDs,
  initialRelayKeysPageState,
  relayKeysPageFetchingIDs,
  type RelayKeysPageState,
} from '../relay-keys-page-state';
import { RelayApiKeyDialog, RelayKeyInputShell, RelayKeyTextField } from './RelayApiKeyDialog';
import styles from '../ProviderDetail.module.css';
import boardStyles from './RelayDetailBoard.module.css';

type RelayKeyCheck = { ok: true } | { ok: false; message: string };

const ACTION_TITLE_KEYS = {
  rename: 'pages.providerDetail.renameProviderTitle',
  replace: 'pages.relayDetail.keyReplace',
  delete: 'common.delete',
} as const;

/** Action description row icon (duotone 22, following iOS actionIcon / actionTint). */
const ACTION_ICONS: Record<keyof typeof ACTION_TITLE_KEYS, { Icon: Icon; color: string }> = {
  rename: { Icon: PencilSimpleIcon, color: 'var(--o-primary)' },
  replace: { Icon: ArrowsClockwiseIcon, color: 'var(--o-row-cyan)' },
  delete: { Icon: TrashIcon, color: 'var(--o-error)' },
};

/** Marker before the status word: dot / warning / fetching spinner. */
function StatusMark({ mark }: { mark: RelayKeyStatusMark }) {
  return (
    <span className={boardStyles.statusMark} data-status-mark={mark} aria-hidden="true">
      {mark === 'warning' && <WarningIcon size={14} weight="fill" />}
      {mark === 'progress' && <CircleNotchIcon size={14} className={boardStyles.spin} />}
    </span>
  );
}

/** Display data of one key row (shared by the keys page and the inline list on the detail page). */
export interface RelayKeyRowViewData {
  title: string;
  primaryBadge: boolean;
  primaryBadgeText: string;
  preview: string;
  catalog: string;
  /** null when never checked: the whole status (marker + word) is not drawn and screen readers do not read it. */
  statusText: string | null;
  statusMark: RelayKeyStatusMark | null;
  enabledUsing?: string;
  last?: string | null;
}

/**
 * Key row (following iOS RelayKeyRowView): the whole row is centered, left column [title + badge / "<mask> · catalog" / enabled count / latest status]
 * | right column [status (marker + word, at most 2 lines)] | caretRight 14. An unnamed key's title is the mask, so the catalog line does not repeat the mask.
 * `element="button"` is used on the keys page (the whole row is tappable); `"span"` is used inside the left column of the API key row on the detail page (the outer row is the tap target).
 */
export function RelayKeyRowView({
  data,
  element,
  className,
  rootAttrs,
  onClick,
  disabled,
  ariaLabel,
  chevron = true,
}: {
  data: RelayKeyRowViewData;
  element: 'button' | 'span';
  className?: string;
  rootAttrs?: Record<`data-${string}`, string>;
  onClick?: MouseEventHandler<HTMLButtonElement>;
  disabled?: boolean;
  ariaLabel?: string;
  /** When inlined on the detail page the outer row already has a chevron, so it is not drawn again. */
  chevron?: boolean;
}) {
  const warning = data.statusMark === 'warning';
  const showsMask = Boolean(data.preview) && data.title !== data.preview;
  const content = (
    <span className={boardStyles.keyRowInner}>
      {/* Split columns (same algorithm as the row layout): total excludes the trailing chevron, and the status column is at most 50%. */}
      <span className={boardStyles.keyColumns} data-row-columns>
        <span className={boardStyles.keyLead} data-row-lead>
          <span className={boardStyles.keyNameLine}>
            <span className={boardStyles.keyName} data-row-title>{data.title}</span>
            {data.primaryBadge && <span className={boardStyles.keyBadge}>{data.primaryBadgeText}</span>}
          </span>
          <span className={boardStyles.keyMeta} data-row-catalog>
            {showsMask && (
              <>
                <span className={boardStyles.keyPreview} data-row-mask>{data.preview}</span>
                <span aria-hidden="true"> · </span>
              </>
            )}
            <span>{data.catalog}</span>
          </span>
          {data.enabledUsing && <span className={boardStyles.keyMeta}>{data.enabledUsing}</span>}
          {data.last && <span className={boardStyles.keyMeta} data-tone="warning">{data.last}</span>}
        </span>
        {data.statusText !== null && (
          <span className={boardStyles.keyTrailing} data-row-trailing>
            <span className={boardStyles.keyStatusLine} data-row-status data-tone={warning ? 'warning' : undefined}>
              {/* The marker is an inline prefix on the first line of the status word: one text flow, and U+2060 keeps it from breaking away from the first word. */}
              <span className={boardStyles.keyStatusText} data-row-status-text>
                {data.statusMark && <StatusMark mark={data.statusMark} />}
                {data.statusMark ? `\u2060${data.statusText}` : data.statusText}
              </span>
            </span>
          </span>
        )}
      </span>
      {chevron && <CaretRightIcon size={14} className={boardStyles.rowChevron} aria-hidden="true" />}
    </span>
  );
  const rootClass = `${boardStyles.keyRow}${className ? ` ${className}` : ''}`;
  if (element === 'button') {
    return (
      <button
        type="button"
        className={rootClass}
        data-relay-key-row
        {...rootAttrs}
        aria-label={ariaLabel}
        onClick={onClick}
        disabled={disabled}
      >
        {content}
      </button>
    );
  }
  return <span className={rootClass} data-relay-key-row {...rootAttrs}>{content}</span>;
}

type Sheet =
  | { type: 'panel' | 'rename' | 'replace' | 'delete'; id: string }
  | { type: 'add' }
  | null;

interface RelayKeysPageProps {
  provider: Provider;
  backLabel: string;
  onBack: () => void;
  /** Swapping the key of the implicit single key goes through the existing single-key replace-Key dialog path (not written to the list). */
  onReplaceImplicitKey: () => void;
  /** Open the model library filtered by key(id) (links from the panel's View models and the added-successfully notice). */
  onOpenLibrary: (keyID: string) => void;
  /** Plaintext interlock and charset go through the shared form validation; this page does not duplicate the criteria. */
  validateKey: (raw: string) => RelayKeyCheck;
  disabled: boolean;
  /** Page state (in-flight fetches, notices) is held by the parent: it is kept when going to the model library and back (same as iOS / Android). */
  pageState: RelayKeysPageState;
  onPageStateChange: Dispatch<SetStateAction<RelayKeysPageState>>;
}

/** Initial keys page state; sample preset (development builds only, always null in production): which keys show "still fetching" and the preset notices. */
export function initialRelayKeysPageStateFromSeed(): RelayKeysPageState {
  const detail = relayShotSeed()?.detail;
  const fetchingIDs = detail?.keysFetchingIDs;
  return {
    ...initialRelayKeysPageState,
    ...(fetchingIDs ? { fetching: Object.fromEntries(fetchingIDs.map((id) => [id, 1])) } : {}),
    ...(detail?.keysNotices ? { notices: detail.keysNotices } : {}),
  };
}

/**
 * Keys page: each key's status is read only from `RelayKey.status`, with no extra probing;
 * add / replace key / delete / move up and down / rename all go through `applyRelayKeyOperation`.
 */
export function RelayKeysPage({
  provider,
  backLabel,
  onBack,
  onReplaceImplicitKey,
  onOpenLibrary,
  validateKey,
  disabled,
  pageState,
  onPageStateChange: setPageState,
}: RelayKeysPageProps) {
  const tRoot = useTranslations();
  const locale = useLocale();
  // Sample preset (development builds only, always null in production): whether to open the add-key dialog on entering the page.
  const board = relayKeysBoard(provider, relayKeysPageFetchingIDs(pageState));
  const [sheet, setSheet] = useState<Sheet>(() => (relayShotSeed()?.detail?.keysAddOpen ? { type: 'add' } : null));
  const actionNotesTitleID = useId();
  const text = (value: KeyText) => tRoot(value.key, value.values);
  const rowTitle = (row: RelayKeysPageRow) => row.title || tRoot('pages.providerDetail.hero.tapToSet');
  const current = sheet && 'id' in sheet ? board.rows.find((row) => row.id === sheet.id) : undefined;
  const indexOf = (id: string) => board.rows.findIndex((row) => row.id === id);

  /** The outcome of each operation is handed to the page state (fetching / notice) instead of fire-and-forget. */
  const run = async (op: RelayKeyOp) => {
    const fetchedIDs = relayKeyOpFetchingIDs(op, provider);
    setPageState((state) => beginRelayKeyOp(state, op, fetchedIDs));
    const store = getVanillaStore();
    let accepted = false;
    try {
      accepted = await applyRelayKeyOperation(store, provider, op);
    } catch {
      accepted = false;
    }
    const latest = store.getState().providers.find((item) => item.id === provider.id);
    setPageState((state) => finishRelayKeyOp(state, op, accepted, latest, fetchedIDs));
  };

  const placeholderText = (field: RelayKeyInputField) => {
    if (!field.placeholder) return '';
    return 'literal' in field.placeholder ? field.placeholder.literal : text(field.placeholder);
  };

  const move = (row: RelayKeysPageRow, delta: -1 | 1) => {
    setSheet(null);
    void run({ type: 'move', id: row.id, toIndex: indexOf(row.id) + delta });
  };

  const startReplace = (row: RelayKeysPageRow) => {
    if (board.implicit) {
      setSheet(null);
      onReplaceImplicitKey();
      return;
    }
    setSheet({ type: 'replace', id: row.id });
  };

  const lastStatusText = (row: RelayKeysPageRow) => {
    if (!row.lastStatus) return null;
    const { httpStatus, statusKey, checkedAt } = row.lastStatus;
    return tRoot('pages.relayDetail.keyLastStatus', {
      status: `${httpStatus} ${tRoot(statusKey)}`,
      time: checkedAt
        ? formatCompactRelativeTime(checkedAt, new Date(), locale, {
          justNow: tRoot('pages.relayDetail.relativeJustNow'),
          minutesAgo: (count) => tRoot('pages.relayDetail.relativeMinutesAgo', { count }),
          hoursAgo: (count) => tRoot('pages.relayDetail.relativeHoursAgo', { count }),
          yesterday: tRoot('pages.relayDetail.relativeYesterday'),
        })
        : '—',
    });
  };

  return (
    <div className={boardStyles.board} data-form="relay">
      {/* Page header: back on the same line as the title, with the subtitle below. */}
      <div className={boardStyles.keysHeader}>
        <div className={boardStyles.keysTitleLine}>
          <BackButton className={styles.backBtn} label={backLabel} onClick={onBack} />
          <h1 className={boardStyles.keysTitle}>{tRoot('pages.relayDetail.keysTitle')}</h1>
        </div>
        <p className={boardStyles.statusLine}>
          {`${board.host} · ${tRoot('pages.relayDetail.keysCount', { count: board.count })}`}
        </p>
      </div>

      {/* Block order: card, then notice, then footnote, then action descriptions; "the first key is the primary key" is the group title above the card (only with 2 or more keys). */}
      <section className={boardStyles.section}>
        {board.showsPrimaryHint && (
          <h2 className={boardStyles.keysGroupTitle}>{tRoot('pages.relayDetail.keysPrimaryHint')}</h2>
        )}
        <div className={`${boardStyles.card} ${boardStyles.keysCard}`} data-keys-card>
          {board.listItems.map((item) => {
            if (item.kind === 'add') {
              return (
                <button
                  key={item.id}
                  type="button"
                  className={`${boardStyles.row} ${boardStyles.keyAddRow}`}
                  data-key-row={item.id}
                  onClick={() => setSheet({ type: 'add' })}
                  disabled={disabled}
                >
                  <span className={boardStyles.rowIcon} aria-hidden="true"><PlusIcon size={20} /></span>
                  <span className={boardStyles.keyAddTitle}>{tRoot('pages.relayDetail.keysAdd')}</span>
                </button>
              );
            }
            const row = board.rows.find((candidate) => candidate.id === item.id)!;
            return (
              <RelayKeyRowView
                key={row.id}
                element="button"
                data={{
                  title: rowTitle(row),
                  primaryBadge: row.primaryBadge,
                  primaryBadgeText: tRoot('pages.relayDetail.keyPrimaryBadge'),
                  preview: row.preview,
                  catalog: text(row.catalog),
                  statusText: row.statusKey ? tRoot(row.statusKey) : null,
                  statusMark: row.statusMark,
                  enabledUsing: text(row.enabledUsing),
                  last: lastStatusText(row),
                }}
                rootAttrs={{ 'data-key-row': row.id }}
                ariaLabel={rowTitle(row)}
                onClick={() => setSheet({ type: 'panel', id: row.id })}
                disabled={disabled}
              />
            );
          })}
        </div>
      </section>

      {pageState.notices.length > 0 && (
        <ul
          className={boardStyles.keyNotices}
          role="status"
          // Notices are always inline (same as iOS noticeLine): tight against the key card and followed by the footer, with reduced spacing.
          data-inline="true"
        >
          {pageState.notices.map((notice) => (
            <KeyNoticeItem
              key={typeof notice === 'string' ? notice : `added-${notice.keyID}`}
              notice={notice}
              text={text}
              linkText={(key) => tRoot(key)}
              onOpenLibrary={onOpenLibrary}
            />
          ))}
        </ul>
      )}

      <div className={boardStyles.keysFootnotes}>
        {board.footnoteKeys.map((key) => (
          <p key={key} className={boardStyles.footnote} data-keys-footnote>{tRoot(key)}</p>
        ))}
      </div>

      {board.actionNotes.length > 0 && (
        <section className={boardStyles.section} aria-labelledby={actionNotesTitleID}>
          <h2 className={boardStyles.sectionTitle} id={actionNotesTitleID}>{tRoot('pages.relayDetail.keyActionsTitle')}</h2>
          <ul className={`${boardStyles.card} ${boardStyles.keyActionNotes}`}>
            {board.actionNotes.map((note) => {
              const { Icon: ActionIcon, color } = ACTION_ICONS[note.action];
              return (
                <li key={note.action} className={boardStyles.keyActionNote} data-key-action-note={note.action}>
                  <ActionIcon size={22} weight="duotone" className={boardStyles.keyActionNoteIcon} style={{ color }} aria-hidden="true" />
                  <span className={boardStyles.keyActionNoteText}>
                    <span className={boardStyles.keyActionNoteTitle}>{tRoot(ACTION_TITLE_KEYS[note.action])}</span>
                    <span>{tRoot(note.noteKey)}</span>
                  </span>
                </li>
              );
            })}
          </ul>
        </section>
      )}

      {sheet?.type === 'panel' && current && (
        <KeyDialog title={rowTitle(current)} onClose={() => setSheet(null)}>
          <div className={boardStyles.keyActions}>
            {current.actions.includes('viewModels') && (
              <Button
                tone="secondary"
                size="sm"
                onClick={() => {
                  setSheet(null);
                  onOpenLibrary(current.id);
                }}
              >
                {tRoot('pages.relayDetail.keyActionViewModels', { count: current.catalogCount })}
              </Button>
            )}
            {current.actions.includes('rename') && (
              <>
                <Button
                  tone="secondary"
                  size="sm"
                  aria-label={tRoot('pages.providerDetail.renameProviderTitle')}
                  onClick={() => setSheet({ type: 'rename', id: current.id })}
                >
                  {tRoot('pages.providerDetail.renameProviderTitle')}
                </Button>
              </>
            )}
            <Button
              tone="secondary"
              size="sm"
              aria-label={tRoot('pages.relayDetail.keyReplace')}
              onClick={() => startReplace(current)}
            >
              {tRoot('pages.relayDetail.keyReplace')}
            </Button>
            {current.actions.includes('moveUp') && (
              <Button
                tone="secondary"
                size="sm"
                aria-label={tRoot('pages.relayDetail.keyMoveUp')}
                onClick={() => move(current, -1)}
              >
                {tRoot('pages.relayDetail.keyMoveUp')}
              </Button>
            )}
            {current.actions.includes('moveDown') && (
              <Button
                tone="secondary"
                size="sm"
                aria-label={tRoot('pages.relayDetail.keyMoveDown')}
                onClick={() => move(current, 1)}
              >
                {tRoot('pages.relayDetail.keyMoveDown')}
              </Button>
            )}
            {current.actions.includes('delete') && (
              <>
                <Button
                  tone="danger"
                  size="sm"
                  aria-label={tRoot('common.delete')}
                  onClick={() => setSheet({ type: 'delete', id: current.id })}
                >
                  {tRoot('common.delete')}
                </Button>
              </>
            )}
            {current.panelNoteKey && (
              <p className={boardStyles.keyActionHint}>{tRoot(current.panelNoteKey)}</p>
            )}
          </div>
          <div className={styles.confirmActions}>
            <Button tone="secondary" size="sm" onClick={() => setSheet(null)}>{tRoot('common.cancel')}</Button>
          </div>
        </KeyDialog>
      )}

      {sheet?.type === 'rename' && current && (
        <RenameKeyDialog
          initialName={current.title === current.preview ? '' : current.title}
          row={current}
          onClose={() => setSheet(null)}
          onSave={(name) => {
            setSheet(null);
            void run({ type: 'rename', id: current.id, name });
          }}
        />
      )}

      {sheet?.type === 'replace' && current && (() => {
        const replaceSheet = relayKeyInputSheet('replace', current);
        const field = replaceSheet.fields[0]!;
        return (
          <RelayApiKeyDialog
            hasSavedKey={false}
            title={tRoot(replaceSheet.titleKey)}
            fieldLabel={tRoot(field.titleKey)}
            placeholder={placeholderText(field)}
            description={replaceSheet.noteKey ? tRoot(replaceSheet.noteKey) : undefined}
            onValidate={validateKey}
            onSave={(next) => {
              // The dialog closes first and that row shows fetching; the outcome is reported by the page state.
              setSheet(null);
              void run({ type: 'replaceSecret', id: current.id, apiKey: next.trim() });
            }}
            onClose={() => setSheet(null)}
            disabled={disabled}
          />
        );
      })()}

      {sheet?.type === 'delete' && current && (
        <KeyDialog title={tRoot('pages.relayDetail.keyDeleteTitle')} role="alertdialog" onClose={() => setSheet(null)}>
          <div className={styles.confirmDesc}>
            {current.usingModelIDs.length > 0
              ? tRoot('pages.relayDetail.keyDeleteMessage', {
                  count: current.usingModelIDs.length,
                  primary: rowTitle(board.rows[0]!),
                })
              : tRoot('pages.relayDetail.keyDeleteMessageNone')}
          </div>
          {current.usingModelIDs.length > 0 && (
            <ul className={boardStyles.keyModelList}>
              {current.usingModelIDs.map((modelID) => (
                <li key={modelID}>{provider.models.find((model) => model.id === modelID)?.name || modelID}</li>
              ))}
            </ul>
          )}
          <div className={styles.confirmActions}>
            <Button tone="secondary" size="sm" onClick={() => setSheet(null)}>{tRoot('common.cancel')}</Button>
            <Button
              tone="danger"
              size="sm"
              onClick={() => {
                setSheet(null);
                void run({ type: 'delete', id: current.id });
              }}
            >
              {tRoot('common.delete')}
            </Button>
          </div>
        </KeyDialog>
      )}

      {sheet?.type === 'add' && (
        <AddKeyDialog
          requiresCredential={relayProviderRequiresCredential(provider)}
          validateKey={validateKey}
          onClose={() => setSheet(null)}
          onSave={(name, apiKey) => {
            setSheet(null);
            void run({
              type: 'add',
              id: globalThis.crypto.randomUUID().toLowerCase(),
              ...(name ? { name } : {}),
              apiKey,
            });
          }}
        />
      )}
    </div>
  );
}

/** One inline notice: a warning (warning icon + warning-colored body) or an added-successfully notice (success-colored check + trailing link). */
function KeyNoticeItem({
  notice,
  text,
  linkText,
  onOpenLibrary,
}: {
  notice: RelayKeyNotice;
  text: (value: KeyText) => string;
  linkText: (key: string) => string;
  onOpenLibrary: (keyID: string) => void;
}) {
  const view = relayKeyNoticeView(notice);
  return (
    <li
      className={boardStyles.keyNotice}
      data-key-notice={typeof notice === 'string' ? notice : notice.kind}
      data-tone={view.tone}
    >
      {view.tone === 'success' ? (
        <CheckCircleIcon size={16} weight="fill" className={boardStyles.keyNoticeIcon} aria-hidden="true" />
      ) : (
        <WarningIcon size={16} className={boardStyles.keyNoticeIcon} data-tone="warning" aria-hidden="true" />
      )}
      {/* The text takes the remaining width and the link is pushed to the end of the row (same as iOS Spacer layout). */}
      <span className={boardStyles.keyNoticeText}>{view.parts.map(text).join(' · ')}</span>
      {view.link && (
        <button
          type="button"
          className={boardStyles.keyNoticeLink}
          onClick={() => onOpenLibrary(view.link!.keyID)}
        >
          {linkText(view.link.key)}
        </button>
      )}
    </li>
  );
}

function KeyDialog({
  title,
  role = 'dialog',
  onClose,
  children,
}: {
  title: string;
  role?: 'dialog' | 'alertdialog';
  onClose: () => void;
  children: React.ReactNode;
}) {
  const titleId = useId();
  return (
    <div className={styles.confirmOverlay} onClick={onClose}>
      <div
        className={styles.confirmDialog}
        onClick={(event) => event.stopPropagation()}
        role={role}
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div id={titleId} className={styles.confirmTitle}>{title}</div>
        {children}
      </div>
    </div>
  );
}

function RenameKeyDialog({
  initialName,
  row,
  onClose,
  onSave,
}: {
  initialName: string;
  row: RelayKeysPageRow;
  onClose: () => void;
  onSave: (name: string) => void;
}) {
  const tRoot = useTranslations();
  const sheet = relayKeyInputSheet('rename', row);
  const field = sheet.fields[0]!;
  const [draft, setDraft] = useState(initialName);
  const save = () => {
    const name = draft.trim();
    if (name) onSave(name);
  };
  return (
    <RelayKeyInputShell title={tRoot(sheet.titleKey)} onClose={onClose} onSave={save} saveDisabled={!draft.trim()}>
      <RelayKeyTextField
        label={tRoot(field.titleKey)}
        value={draft}
        onChange={setDraft}
        onEnter={save}
        placeholder={field.placeholder && 'literal' in field.placeholder ? field.placeholder.literal : ''}
        autoFocus
      />
      {sheet.noteKey && <div className={styles.confirmDesc}>{tRoot(sheet.noteKey)}</div>}
    </RelayKeyInputShell>
  );
}

function AddKeyDialog({
  requiresCredential,
  validateKey,
  onClose,
  onSave,
}: {
  requiresCredential: boolean;
  validateKey: (raw: string) => RelayKeyCheck;
  onClose: () => void;
  onSave: (name: string, apiKey: string) => void;
}) {
  const tRoot = useTranslations();
  const sheet = relayKeyInputSheet('add');
  const [nameField, secretField] = sheet.fields as [RelayKeyInputField, RelayKeyInputField];
  const placeholder = (field: RelayKeyInputField) => {
    if (!field.placeholder) return undefined;
    return 'literal' in field.placeholder ? field.placeholder.literal : tRoot(field.placeholder.key);
  };
  const [name, setName] = useState('');
  const [secret, setSecret] = useState('');
  const [error, setError] = useState<string | null>(null);
  const save = () => {
    const apiKey = secret.trim();
    // Required-ness depends only on requiresCredential; a blank auth=none connection is not flagged as required and no empty key is added to the pool.
    if (apiKey.length === 0) {
      if (requiresCredential) setError(tRoot('pages.relayDetail.apiKeyRequired'));
      return;
    }
    const check = validateKey(apiKey);
    if (!check.ok) {
      setError(check.message);
      return;
    }
    onSave(name.trim(), apiKey);
  };
  return (
    <RelayKeyInputShell title={tRoot(sheet.titleKey)} onClose={onClose} onSave={save} saveDisabled={!secret.trim()}>
      <RelayKeyTextField
        label={tRoot(nameField.titleKey)}
        value={name}
        onChange={setName}
        onEnter={save}
        placeholder={placeholder(nameField)}
        autoFocus
      />
      <RelayKeyTextField
        label={tRoot(secretField.titleKey)}
        value={secret}
        onChange={(value) => {
          setSecret(value);
          if (error) setError(null);
        }}
        onEnter={save}
        placeholder={placeholder(secretField)}
        secret
      />
      {error && <div className={styles.editFieldError} role="alert">{error}</div>}
    </RelayKeyInputShell>
  );
}
