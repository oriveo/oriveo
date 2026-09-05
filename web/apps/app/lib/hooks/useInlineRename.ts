import { useState, useRef, useEffect, useCallback, type KeyboardEvent } from 'react';

interface UseInlineRenameParams {
  /** Initial value shown when editing starts (conversation title or folder name). */
  initialValue: string;
  /** Optional maximum length; folder names use 30. */
  maxLength?: number;
  /** Only invoked when the value is non-empty and differs from the initial value. */
  onSubmit: (value: string) => void;
}

/**
 * Inline rename: enter edit mode, focus automatically, submit on Enter or blur, cancel on Esc.
 * Shared by ConversationItem and FolderItem.
 */
export function useInlineRename({ initialValue, maxLength, onSubmit }: UseInlineRenameParams) {
  const [editing, setEditing] = useState(false);
  const [value, setValueState] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (editing) inputRef.current?.focus();
  }, [editing]);

  const start = useCallback(() => {
    setValueState(initialValue);
    setEditing(true);
  }, [initialValue]);

  const setValue = useCallback(
    (next: string) => {
      setValueState(maxLength != null ? next.slice(0, maxLength) : next);
    },
    [maxLength],
  );

  const submit = useCallback(() => {
    const trimmed = value.trim();
    if (trimmed && trimmed !== initialValue) {
      onSubmit(trimmed);
    }
    setEditing(false);
  }, [value, initialValue, onSubmit]);

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        submit();
      }
      if (e.key === 'Escape') {
        setEditing(false);
      }
    },
    [submit],
  );

  return { editing, value, setValue, inputRef, start, submit, handleKeyDown };
}
