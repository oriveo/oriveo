import { screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { StreamActivityLine } from '../../chat/StreamActivityLine';
import { renderWithIntl } from './mcp-test-kit';

vi.mock('next-intl', async () => await import('use-intl'));

describe('activity line copy for mcp_tool', () => {
  it('shows server name · tool title, leaves third-party text untranslated and has no trailing ellipsis', () => {
    renderWithIntl(<StreamActivityLine label="mcp_tool" mcp={{ server: 'Notion', tool: 'Find page' }} />);
    expect(screen.getByRole('status').textContent).toBe('Using Notion · Find page');
  });

  it('falls back to neutral copy when there is no display context', () => {
    renderWithIntl(<StreamActivityLine label="mcp_tool" />);
    expect(screen.getByRole('status').textContent).toBe('Generating');
  });

  it('leaves the web search copy unaffected', () => {
    renderWithIntl(<StreamActivityLine label="web_search" mcp={{ server: 'Notion', tool: 'Find page' }} />);
    expect(screen.getByRole('status').textContent).toBe('Searching the web');
  });
});
