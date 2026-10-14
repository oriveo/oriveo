'use client';

import { useEffect, useRef, useState, type ComponentType, type ReactNode, type RefObject } from 'react';
import { useTranslations } from 'next-intl';
import {
  CaretRightIcon,
  CheckCircleIcon,
  CircleNotchIcon,
  EyeIcon,
  HardDrivesIcon,
  KeyIcon,
  LinkIcon,
  PlusIcon,
  ShieldCheckIcon,
  TrashIcon,
  WarningIcon,
  XIcon,
  type IconProps,
} from '@phosphor-icons/react';
import type { RelayFormIssue } from '@oriveo/core/providers/relay-form-validation';
import { Button } from '@oriveo/ui';
import {
  EDIT_ENDPOINT_SLOT_PLACEHOLDER,
  endpointFromSlotInput,
  endpointSchemeChip,
  endpointSlotText,
} from '../../relay/new/setup-board-parts';
import {
  RELAY_EDIT_TEXT,
  relayEditRevealsStatus,
  relayRevealsFailureCard,
  type EditGroup,
  type EditIcon,
  type EditRow,
  type EditText,
  type RelayEditBoard,
  type RelayEditDraft,
  type RelayEditStatus,
} from '../relay-edit-board';
import boardStyles from './RelayDetailBoard.module.css';
import setupStyles from '../../relay/new/RelaySetup.module.css';
import detailStyles from '../ProviderDetail.module.css';
import styles from './RelayEditConnection.module.css';

const ROW_ICONS: Record<EditIcon, ComponentType<IconProps>> = {
  link: LinkIcon,
  'shield-check': ShieldCheckIcon,
  'hard-drives': HardDrivesIcon,
  key: KeyIcon,
};

export interface RelayEditConnectionProps {
  board: RelayEditBoard;
  draft: RelayEditDraft;
  /** Original state (the reveal criteria need both the before and after states). */
  status: RelayEditStatus | null;
  /** Whether inputs are locked (saving / reconnecting in progress). */
  locked: boolean;
  /** Incremented by the parent when the address is normalized and written back: selects the address in the input. */
  endpointRevealVersion: number;
  issueMessage: (issue: RelayFormIssue) => string;
  onDraftChange: (patch: Partial<RelayEditDraft>) => void;
  onToggleGroup: (group: EditGroup) => void;
  /** Control of the connection security row (selecting it saves and reconnects immediately); the footnote is drawn by the control in the left column of the row. */
  renderSecurityControl: (icon: ReactNode, footnote?: ReactNode) => ReactNode;
  onTest: () => void;
  onPrimary: () => void;
  onClose: () => void;
  /** Verification failure card (reason + technical details + "Save anyway (unverified)"). */
  failureCard: ReactNode;
  showDiscardConfirm: boolean;
  onKeepEditing: () => void;
  onDiscard: () => void;
}

/** Edit connection (the "Edit connection" section of the UI spec): renders only from the output of relayEditBoard. */
export function RelayEditConnection(props: RelayEditConnectionProps) {
  const { board, draft, status, locked } = props;
  const tRoot = useTranslations();
  const endpointInputRef = useRef<HTMLInputElement>(null);
  const statusRef = useRef<HTMLDivElement>(null);
  const failureRef = useRef<HTMLDivElement>(null);
  const previousStatus = useRef<RelayEditStatus | null>(status);
  const previousFailure = useRef<true | null>(props.failureCard ? true : null);
  const text = useEditText();

  // Dismiss the keyboard and scroll over only when a result appears or changes; an in-flight one replaced in place by its result does not move.
  useEffect(() => {
    const previous = previousStatus.current;
    previousStatus.current = status;
    if (!relayEditRevealsStatus(previous, status)) return;
    (document.activeElement as HTMLElement | null)?.blur?.();
    statusRef.current?.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' });
  }, [status]);

  const hasFailure = Boolean(props.failureCard);
  useEffect(() => {
    const previous = previousFailure.current;
    const next = hasFailure ? true : null;
    previousFailure.current = next;
    if (!relayRevealsFailureCard(previous, next)) return;
    (document.activeElement as HTMLElement | null)?.blur?.();
    failureRef.current?.scrollIntoView?.({ block: 'nearest', behavior: 'smooth' });
  }, [hasFailure]);

  const { endpointRevealVersion } = props;
  useEffect(() => {
    if (endpointRevealVersion <= 0) return;
    endpointInputRef.current?.focus();
    endpointInputRef.current?.select();
  }, [endpointRevealVersion]);

  const statusLine = board.status;
  return (
    <div className={styles.page} data-edit-form={board.form}>
      <header className={styles.header}>
        <button type="button" className={styles.closeButton} onClick={props.onClose} aria-label={tRoot('common.close')}>
          <XIcon size={18} weight="bold" aria-hidden="true" />
        </button>
        <div className={styles.headerTitle}>
          <h1>{tRoot(board.titleKey)}</h1>
          <p>{board.subtitle}</p>
        </div>
      </header>

      {/* At phone width only this section scrolls; the title bar and action bar stay fixed. */}
      <div className={styles.body} data-edit-body>
        {board.groups.map((group) => (
          <RelayEditGroupView
            key={group.id}
            group={group}
            draft={draft}
            locked={locked}
            issueMessage={props.issueMessage}
            onDraftChange={props.onDraftChange}
            onToggleGroup={props.onToggleGroup}
            endpointInputRef={endpointInputRef}
            renderSecurityControl={props.renderSecurityControl}
          />
        ))}

        {statusLine && (
          <div
            ref={statusRef}
            className={styles.status}
            data-tone={statusLine.tone}
            data-status={statusLine.kind}
            role="status"
          >
            {statusLine.spinning && <CircleNotchIcon size={16} className={setupStyles.spinner} aria-hidden="true" />}
            {statusLine.icon === 'check-circle' && <CheckCircleIcon size={16} weight="fill" aria-hidden="true" />}
            {statusLine.icon === 'warning' && <WarningIcon size={16} weight="fill" aria-hidden="true" />}
            <span>{text(statusLine.text)}</span>
          </div>
        )}

        {props.failureCard && <div ref={failureRef}>{props.failureCard}</div>}
      </div>

      <div className={`${setupStyles.actionBar} ${styles.actionBar}`}>
        <Button
          tone="secondary"
          onClick={props.onTest}
          disabled={!board.actionBar.test.enabled}
          data-edit-action="test"
        >
          {tRoot(board.actionBar.test.titleKey)}
        </Button>
        <Button
          tone="primary"
          onClick={props.onPrimary}
          disabled={!board.actionBar.primary.enabled}
          data-edit-action="primary"
        >
          {tRoot(board.actionBar.primary.titleKey)}
        </Button>
      </div>

      {props.showDiscardConfirm && (
        <div className={detailStyles.confirmOverlay} onClick={props.onKeepEditing}>
          <div
            className={detailStyles.confirmDialog}
            role="alertdialog"
            aria-modal="true"
            aria-label={tRoot(RELAY_EDIT_TEXT.discardTitle)}
            onClick={(event) => event.stopPropagation()}
          >
            <div className={detailStyles.confirmTitle}>{tRoot(RELAY_EDIT_TEXT.discardTitle)}</div>
            <div className={detailStyles.confirmDesc}>{tRoot(RELAY_EDIT_TEXT.unsavedMessage)}</div>
            <div className={detailStyles.confirmActions}>
              <Button tone="secondary" size="sm" onClick={props.onKeepEditing}>{tRoot(RELAY_EDIT_TEXT.keepEditing)}</Button>
              <Button tone="danger" size="sm" onClick={props.onDiscard}>{tRoot(RELAY_EDIT_TEXT.discard)}</Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** A group of rows for edit connection (connection / protocol and auth / headers / compatibility): the manual-setup protocol card and collapsible groups render from it too. */
export interface RelayEditGroupViewProps {
  group: EditGroup;
  draft: RelayEditDraft;
  locked: boolean;
  issueMessage: (issue: RelayFormIssue) => string;
  onDraftChange: (patch: Partial<RelayEditDraft>) => void;
  onToggleGroup: (group: EditGroup) => void;
  endpointInputRef?: RefObject<HTMLInputElement | null>;
  /** Control of the connection security row (only edit connection has this row). */
  renderSecurityControl?: (icon: ReactNode, footnote?: ReactNode) => ReactNode;
}

function useEditText() {
  const tRoot = useTranslations();
  return (value: EditText | undefined): string => {
    if (!value) return '';
    if ('literal' in value) return value.literal;
    if (!('keyValues' in value)) return value.values ? tRoot(value.key, value.values) : tRoot(value.key);
    const keyValues = Object.fromEntries(Object.entries(value.keyValues).map(([name, key]) => [name, tRoot(key)]));
    return tRoot(value.key, { ...value.values, ...keyValues });
  };
}

export function RelayEditGroupView({
  group,
  draft,
  locked,
  issueMessage,
  onDraftChange,
  onToggleGroup,
  endpointInputRef,
  renderSecurityControl,
}: RelayEditGroupViewProps) {
  const tRoot = useTranslations();
  const text = useEditText();
  const [revealedHeaders, setRevealedHeaders] = useState<ReadonlySet<number>>(new Set());
  const [addMenuOpen, setAddMenuOpen] = useState(false);

  const updateEntry = (list: 'headers' | 'queryParams', index: number, patch: { key?: string; value?: string }) => {
    onDraftChange({
      [list]: draft[list].map((entry, entryIndex) => (entryIndex === index ? { ...entry, ...patch } : entry)),
    });
  };
  const removeEntry = (list: 'headers' | 'queryParams', index: number) => {
    onDraftChange({ [list]: draft[list].filter((_entry, entryIndex) => entryIndex !== index) });
    if (list === 'headers') setRevealedHeaders(new Set());
  };
  const addEntry = (list: 'headers' | 'queryParams') => {
    onDraftChange({ [list]: [...draft[list], { key: '', value: '' }] });
    setAddMenuOpen(false);
  };

  const rowIcon = (row: EditRow) => {
    if (!row.icon) return null;
    const Icon = ROW_ICONS[row.icon];
    return (
      <span
        className={boardStyles.rowIcon}
        data-row-icon={row.icon}
        style={row.colorToken ? { color: `var(${row.colorToken})` } : undefined}
        aria-hidden="true"
      >
        <Icon size={22} weight="duotone" />
      </span>
    );
  };

  const footnote = (row: EditRow, className = styles.footnote) => (row.footnote
    ? <small className={className} data-row-footnote={row.id}>{text(row.footnote)}</small>
    : null);

  // iOS rowBody: left column [icon + title; footnote indented to the title], value and trailing control together in the trailing column, whole row vertically centered.
  const rowLead = (row: EditRow, title: ReactNode) => (
    <span className={styles.rowLead} data-row-lead>
      {rowIcon(row)}
      <span className={styles.rowText}>
        {title}
        {footnote(row)}
      </span>
    </span>
  );

  const issueLine = (issue: RelayFormIssue) => (
    <span key={`${issue.field}-${issue.code}`} className={setupStyles.fieldError} role="alert" data-issue-field={issue.field}>
      {issueMessage(issue)}
    </span>
  );

  const renderEntry = (row: EditRow, group: EditGroup) => {
    const list = row.id === 'header' ? 'headers' : 'queryParams';
    const index = row.entryIndex ?? 0;
    const entry = draft[list][index] ?? { key: '', value: '' };
    const masked = row.masked && !revealedHeaders.has(index);
    const field = row.id === 'header' ? 'headers' : 'query_params';
    const isLastOfKind = index === draft[list].length - 1;
    return (
      <div key={`${row.id}-${index}`} className={styles.entryBlock}>
        <div className={`${styles.entryRow} ${styles.entryRowWrap}`} data-edit-row={row.id}>
          <span className={styles.entryKind}>{tRoot(row.titleKey)}</span>
          <span className={styles.entryFields}>
            <input
              className={styles.slot}
              value={entry.key}
              aria-label={`${tRoot(row.titleKey)} ${index + 1}`}
              placeholder={tRoot('pages.relayDetail.keyPlaceholder')}
              onChange={(event) => updateEntry(list, index, { key: event.target.value })}
              autoComplete="off"
              spellCheck={false}
              disabled={locked}
            />
            <span className={styles.valueSlot}>
              <input
                className={styles.slot}
                value={entry.value}
                type={masked ? 'password' : 'text'}
                aria-label={`${tRoot(row.titleKey)} ${index + 1} ${tRoot('pages.relayDetail.valuePlaceholder')}`}
                placeholder={tRoot('pages.relayDetail.valuePlaceholder')}
                onChange={(event) => updateEntry(list, index, { value: event.target.value })}
                autoComplete="off"
                spellCheck={false}
                disabled={locked}
              />
              {row.masked && (
                <button
                  type="button"
                  className={styles.iconButton}
                  onClick={() => setRevealedHeaders((current) => {
                    const next = new Set(current);
                    if (next.has(index)) next.delete(index); else next.add(index);
                    return next;
                  })}
                  aria-label={tRoot(masked ? 'pages.providerDetail.showKey' : 'pages.providerDetail.hideKey')}
                >
                  <EyeIcon size={18} weight={masked ? 'regular' : 'duotone'} aria-hidden="true" />
                </button>
              )}
            </span>
            <button
              type="button"
              className={styles.iconButton}
              onClick={() => removeEntry(list, index)}
              aria-label={`${tRoot(row.id === 'header' ? 'pages.relayDetail.removeHeader' : 'pages.relayDetail.removeQueryParam')} ${index + 1}`}
              disabled={locked}
            >
              <TrashIcon size={18} aria-hidden="true" />
            </button>
          </span>
        </div>
        {/* Hints for headers / query parameters appear below the last row of that field. */}
        {isLastOfKind && group.issues.filter((issue) => issue.field === field).map(issueLine)}
      </div>
    );
  };

  const renderRow = (row: EditRow, group: EditGroup): ReactNode => {
    switch (row.id) {
      case 'requestURL':
      case 'engineAddress':
        return (
          <div key={row.id} className={styles.fieldRow} data-edit-row={row.id} data-has-icon={row.icon ? 'true' : undefined}>
            <div className={styles.rowHead}>
              {rowIcon(row)}
              <label htmlFor="relay-edit-endpoint" className={boardStyles.rowTitle}>{tRoot(row.titleKey)}</label>
            </div>
            <div className={`${setupStyles.inputShell} ${styles.fieldIndent}`}>
              <span className={setupStyles.schemeChip} aria-hidden="true">{endpointSchemeChip(draft.endpoint)}</span>
              <input
                ref={endpointInputRef}
                id="relay-edit-endpoint"
                className={setupStyles.shellInput}
                type="url"
                value={endpointSlotText(draft.endpoint)}
                placeholder={row.id === 'requestURL' ? EDIT_ENDPOINT_SLOT_PLACEHOLDER : undefined}
                onChange={(event) => onDraftChange({ endpoint: endpointFromSlotInput(draft.endpoint, event.target.value) })}
                autoComplete="off"
                autoCapitalize="off"
                spellCheck={false}
                inputMode="url"
                disabled={locked}
              />
            </div>
            {footnote(row, `${styles.footnote} ${styles.fieldIndent} ${styles.footnoteClamp}`)}
          </div>
        );
      case 'connectionSecurity': {
        const Icon = ROW_ICONS['shield-check'];
        return (
          <div key={row.id} className={styles.securityRow} data-edit-row={row.id}>
            {renderSecurityControl?.(
              <span style={{ color: `var(${row.colorToken})`, display: 'inline-flex' }} data-row-icon={row.icon}>
                <Icon size={22} weight="duotone" />
              </span>,
              footnote(row),
            )}
          </div>
        );
      }
      case 'defaultProtocol':
      case 'authentication':
      case 'channel':
        return (
          <div key={row.id} className={styles.menuRow} data-edit-row={row.id}>
            {rowLead(row, <span className={styles.menuTitle}>{tRoot(row.titleKey)}</span>)}
            <span className={styles.rowTrailing} data-row-trailing>
              {row.options ? (
                <select
                  className={styles.menu}
                  aria-label={tRoot(row.titleKey)}
                  value={row.id === 'authentication' ? draft.authMode : draft.transport}
                  onChange={(event) => onDraftChange(row.id === 'authentication'
                    ? { authMode: event.target.value as RelayEditDraft['authMode'] }
                    : { transport: event.target.value as RelayEditDraft['transport'] })}
                  disabled={locked}
                >
                  {row.options.map((option) => (
                    <option key={option.value} value={option.value}>{text(option.label)}</option>
                  ))}
                </select>
              ) : (
                <span className={styles.menuValue} data-readonly="true">{text(row.value)}</span>
              )}
            </span>
          </div>
        );
      case 'userAgent':
        return (
          <label key={row.id} className={styles.entryRow} data-edit-row={row.id}>
            <span className={styles.entryKind}>{tRoot(row.titleKey)}</span>
            <input
              className={styles.slot}
              value={draft.customUserAgent}
              onChange={(event) => onDraftChange({ customUserAgent: event.target.value })}
              autoComplete="off"
              spellCheck={false}
              disabled={locked}
            />
          </label>
        );
      case 'header':
      case 'queryParam':
        return renderEntry(row, group);
      case 'addEntry':
        return (
          <div key={row.id} className={styles.addRow} data-edit-row={row.id}>
            <button
              type="button"
              className={styles.addButton}
              onClick={() => setAddMenuOpen((open) => !open)}
              aria-expanded={addMenuOpen}
              aria-haspopup="menu"
              disabled={locked}
            >
              <PlusIcon size={14} weight="bold" aria-hidden="true" />
              {tRoot(row.titleKey)}
            </button>
            {addMenuOpen && (
              <div className={styles.addMenu} role="menu">
                {row.options?.map((option) => (
                  <button
                    key={option.value}
                    type="button"
                    role="menuitem"
                    className={styles.addMenuItem}
                    onClick={() => addEntry(option.value === 'header' ? 'headers' : 'queryParams')}
                  >
                    {text(option.label)}
                  </button>
                ))}
              </div>
            )}
          </div>
        );
      case 'stream':
      case 'disableResponseStorage':
        return (
          <div key={row.id} className={styles.menuRow} data-edit-row={row.id}>
            {rowLead(row, <label htmlFor={`relay-edit-${row.id}`} className={styles.menuTitle}>{tRoot(row.titleKey)}</label>)}
            <span className={styles.rowTrailing} data-row-trailing>
              <input
                id={`relay-edit-${row.id}`}
                type="checkbox"
                role="switch"
                className={styles.toggle}
                checked={row.checked === true}
                onChange={(event) => onDraftChange(row.id === 'stream'
                  ? { stream: event.target.checked }
                  : { disableResponseStorage: event.target.checked })}
                disabled={locked}
              />
            </span>
          </div>
        );
      case 'serviceTier':
        return (
          <label key={row.id} className={styles.entryRow} data-edit-row={row.id}>
            <span className={styles.entryKind}>{tRoot(row.titleKey)}</span>
            <input
              className={styles.slot}
              value={draft.serviceTier}
              onChange={(event) => onDraftChange({ serviceTier: event.target.value })}
              autoComplete="off"
              spellCheck={false}
              disabled={locked}
            />
          </label>
        );
    }
  };

  const trailingText = group.trailingParts
    ? group.trailingParts.map((part) => text(part)).join(' · ')
    : group.trailing ? text(group.trailing) : '';
  const trailing = trailingText ? <span className={boardStyles.rowTrailing}>{trailingText}</span> : null;
  // Validation hints not belonging to a row (hints outside the headers group all go under the connection card).
  const looseIssues = group.id === 'headers'
    ? group.issues.filter((issue) => {
        const list = issue.field === 'headers' ? draft.headers : draft.queryParams;
        return list.length === 0;
      })
    : group.issues;
  return (
    <section className={boardStyles.section} data-edit-group={group.id}>
      {group.collapsible ? (
        <button
          type="button"
          className={styles.groupToggle}
          aria-expanded={group.expanded}
          onClick={() => onToggleGroup(group)}
        >
          <span className={boardStyles.sectionTitle}>{tRoot(group.titleKey)}</span>
          {trailing}
          <CaretRightIcon size={12} className={styles.caret} data-expanded={group.expanded} aria-hidden="true" />
        </button>
      ) : (
        <h2 className={boardStyles.sectionTitle}>{tRoot(group.titleKey)}</h2>
      )}
      {group.expanded && (
        <div className={boardStyles.card}>
          {group.rows.map((row) => renderRow(row, group))}
        </div>
      )}
      {looseIssues.length > 0 && <div className={styles.issues}>{looseIssues.map(issueLine)}</div>}
    </section>
  );
}
