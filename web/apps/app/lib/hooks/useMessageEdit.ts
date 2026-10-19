import { useState, useCallback, useEffect } from 'react';

/** Reopen this message's edit box with the given text (edit-and-resend cancelled at the pre-send confirm, P9·U8). */
export interface MessageEditReopen {
  text: string;
  nonce: number;
}

/**
 * Hook holding message edit state, wrapping the editing state and callbacks used by MessageBubble.
 */
export function useMessageEdit(
  originalText: string,
  onEditAndResend?: (newText: string) => void,
  reopen?: MessageEditReopen,
) {
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');

  useEffect(() => {
    if (!reopen) return;
    setEditText(reopen.text);
    setEditing(true);
  }, [reopen]);

  const handleStartEdit = useCallback(() => {
    setEditText(originalText);
    setEditing(true);
  }, [originalText]);

  const handleCancelEdit = useCallback(() => {
    setEditing(false);
    setEditText('');
  }, []);

  const handleSubmitEdit = useCallback(() => {
    const trimmed = editText.trim();
    if (trimmed && trimmed !== originalText) {
      onEditAndResend?.(trimmed);
    }
    setEditing(false);
    setEditText('');
  }, [editText, originalText, onEditAndResend]);

  const handleEditKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        handleSubmitEdit();
      }
      if (e.key === 'Escape') handleCancelEdit();
    },
    [handleSubmitEdit, handleCancelEdit],
  );

  return {
    editing, editText, setEditText,
    handleStartEdit, handleCancelEdit, handleSubmitEdit, handleEditKeyDown,
  };
}
