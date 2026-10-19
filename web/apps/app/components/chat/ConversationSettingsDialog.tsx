'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Button, CloseButton, Dialog } from '@oriveo/ui';
import type { Conversation } from '@oriveo/shared';
import { getVanillaStore, useAppStore } from '../../providers/StoreProvider';
import { updateConversationUseMemory } from '../../lib/core/conversation-ops';
import {
  carryOverSource,
  commitConversationSettings,
} from '../../lib/core/chat/conversation-instructions/conversation-settings';
import { McpSwitch } from '../mcp/McpSwitch';
import styles from './ConversationSettingsDialog.module.css';

interface ConversationSettingsDialogProps {
  open: boolean;
  /** Undefined before the first send: edits go to the store draft and are written on create. */
  conversation: Conversation | undefined;
  /** Same rule as MemoryPopover: the memory switch shows only when an active semantic memory item exists. */
  hasMemory?: boolean;
  onClose: () => void;
  /** Context usage row; hidden when not provided. The caller closes this dialog and opens the panel. */
  onOpenUsage?: () => void;
  /** Value shown at the end of the usage row ("N%", about percent or not available). */
  usageValue?: string;
}

export function ConversationSettingsDialog({
  open,
  conversation,
  hasMemory,
  onClose,
  onOpenUsage,
  usageValue,
}: ConversationSettingsDialogProps) {
  const t = useTranslations('pages.chat.conversationSettings');
  const tCommon = useTranslations('common');
  const tMemory = useTranslations('pages.memory');
  const draft = useAppStore((s) => s.draftConversationInstructions);
  const conversations = useAppStore((s) => s.conversations);
  // Snapshot on open: closing without edits must not overwrite a remote change made meanwhile.
  const [original] = useState(() => (conversation ? (conversation.instructions ?? '') : draft));
  const [text, setText] = useState(original);

  const carryOver = carryOverSource(conversations, conversation?.id, text);
  const showMemorySwitch = !!conversation && hasMemory === true;
  const useMemory = conversation?.useMemory !== false;

  // Closing is saving: normalized, and skipped when unchanged.
  const handleClose = () => {
    commitConversationSettings(getVanillaStore(), conversation?.id ?? null, original, text);
    onClose();
  };

  // Leaving for the usage panel also closes the dialog, so it saves the same way.
  const handleOpenUsage = () => {
    commitConversationSettings(getVanillaStore(), conversation?.id ?? null, original, text);
    onOpenUsage?.();
  };

  return (
    <Dialog
      open={open}
      onClose={handleClose}
      size="md"
      padded={false}
      ariaLabelledBy="conversation-settings-title"
      lockBodyScroll
    >
      <section className={styles.panel}>
        <CloseButton className={styles.close} label={tCommon('close')} onClick={handleClose} />
        <header className={styles.header}>
          <h2 id="conversation-settings-title" className={styles.title}>
            {t('title')}
          </h2>
        </header>
        <div className={styles.block}>
          <label htmlFor="conversation-settings-instructions" className={styles.sectionLabel}>
            {t('instructionsHeader')}
          </label>
          <textarea
            id="conversation-settings-instructions"
            className={styles.editor}
            value={text}
            placeholder={t('instructionsPlaceholder')}
            onChange={(e) => setText(e.target.value)}
            rows={6}
          />
          <p className={styles.footer}>{t('instructionsFooter')}</p>
          {carryOver !== null ? (
            <button type="button" className={styles.carryOver} onClick={() => setText(carryOver)}>
              {t('carryOver')}
            </button>
          ) : null}
        </div>
        {showMemorySwitch && conversation ? (
          <div className={styles.row}>
            <span>{tMemory('conversationUseMemory')}</span>
            <McpSwitch
              checked={useMemory}
              label={tMemory('conversationUseMemory')}
              onChange={(next) => updateConversationUseMemory(getVanillaStore(), conversation.id, next)}
            />
          </div>
        ) : null}
        {onOpenUsage ? (
          <button type="button" className={styles.rowButton} onClick={handleOpenUsage}>
            <span>{t('usage')}</span>
            {usageValue ? <span className={styles.rowValue}>{usageValue}</span> : null}
          </button>
        ) : null}
        <div className={styles.actions}>
          <Button tone="primary" size="sm" onClick={handleClose}>
            {tCommon('done')}
          </Button>
        </div>
      </section>
    </Dialog>
  );
}
