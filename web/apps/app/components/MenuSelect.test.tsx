import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { MenuSelect } from './MenuSelect';

describe('MenuSelect', () => {
  it('opens the menu and selects a new option', () => {
    const onChange = vi.fn();

    render(
      <MenuSelect
        value="system"
        ariaLabel="Theme"
        options={[
          { value: 'system', label: 'System' },
          { value: 'light', label: 'Light' },
          { value: 'dark', label: 'Dark' },
        ]}
        onChange={onChange}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Theme' }));
    expect(screen.getByRole('menu')).toBeTruthy();

    fireEvent.click(screen.getByRole('menuitemradio', { name: 'Dark' }));

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(onChange).toHaveBeenCalledWith('dark');
    expect(screen.queryByRole('menu')).toBeNull();
  });

  it('supports keyboard selection and returns focus to the trigger', async () => {
    const onChange = vi.fn();

    render(
      <MenuSelect
        value="system"
        ariaLabel="Theme"
        options={[
          { value: 'system', label: 'System' },
          { value: 'light', label: 'Light' },
          { value: 'dark', label: 'Dark' },
        ]}
        onChange={onChange}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'Theme' });

    fireEvent.click(trigger);
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'ArrowDown' });
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Enter' });

    expect(onChange).toHaveBeenCalledWith('light');
    expect(screen.queryByRole('menu')).toBeNull();
    await waitFor(() => {
      expect(document.activeElement).toBe(trigger);
    });
  });

  it('stays open when focusing the menu triggers the initial scroll event', async () => {
    const onChange = vi.fn();

    render(
      <MenuSelect
        value="system"
        ariaLabel="Language"
        options={[
          { value: 'system', label: 'System' },
          { value: 'en', label: 'English' },
          { value: 'zh-Hans', label: '\u7b80\u4f53\u4e2d\u6587' },
        ]}
        onChange={onChange}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Language' }));
    fireEvent.scroll(document);

    expect(screen.getByRole('menu')).toBeTruthy();

    await waitFor(() => {
      expect(screen.getByRole('menu')).toBeTruthy();
    });
  });

  it('shows the selected description in the trigger when requested', () => {
    render(
      <MenuSelect
        value="price"
        ariaLabel="Sort"
        options={[
          { value: 'name', label: 'Name', description: 'A to Z' },
          { value: 'price', label: 'Price', description: 'Low to High' },
        ]}
        showSelectedDescription
        onChange={vi.fn()}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'Sort' });
    expect(trigger.textContent).toContain('Price');
    expect(trigger.textContent).toContain('Low to High');
  });
});
