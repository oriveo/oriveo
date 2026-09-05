import { useState, useCallback } from 'react';

/**
 * Hook holding message edit state, wrapping the editing state and callbacks used by MessageBubble.
 */
export function useMessageEdit(
  originalText: string,
  onEditAndResend?: (newText: string) => void,
) {
  const [editing, setEditing] = useState(false);
  const [editText, setEditText] = useState('');

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
