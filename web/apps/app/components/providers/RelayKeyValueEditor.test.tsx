import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { RelayKeyValueEditor } from './RelayKeyValueEditor';

describe('RelayKeyValueEditor', () => {
  it('ignores rows without a key and preserves rows with an empty value', () => {
    const onChange = vi.fn();
    render(
      <RelayKeyValueEditor
        label="Headers"
        name="headers"
        values={undefined}
        onChange={onChange}
        addLabel="Add"
        removeLabel="Remove"
        keyPlaceholder="Key"
        valuePlaceholder="Value"
      />,
    );

    fireEvent.change(screen.getByLabelText('headers.0.value'), {
      target: { value: 'value-without-key' },
    });
    expect(onChange).toHaveBeenLastCalledWith(undefined);

    fireEvent.change(screen.getByLabelText('headers.0.key'), {
      target: { value: 'X-Empty' },
    });
    fireEvent.change(screen.getByLabelText('headers.0.value'), {
      target: { value: '' },
    });

    expect(onChange).toHaveBeenLastCalledWith([{ key: 'X-Empty', value: '' }]);
  });
});
