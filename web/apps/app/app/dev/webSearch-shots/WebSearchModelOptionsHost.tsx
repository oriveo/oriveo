'use client';

/**
 * Minimal host for the model-options shots, dev route only: mounts the production ModelOptionsPopover (expanded). The web-search card is computed by the production
 * resolveWebSearchRoute → webSearchCardPresentation chain; the service list, sources and catalog are in-memory manifest values, nothing reads or writes the partition database.
 */
import { useState } from 'react';
import { ModelOptionsPopover } from '../../../components/chat/ModelOptionsPopover';
import type { WebSearchModelOptionsShot } from './webSearch-shots-data';

/** The production panel is positioned against the composer (absolutely, flush with its top edge); this provides a same-width container pinned to the bottom of the viewport. */
const COMPOSER_FRAME = { position: 'fixed', insetInline: 0, bottom: 24 } as const;
const COMPOSER_BOX = { position: 'relative', maxWidth: 820, height: 54, margin: '0 auto' } as const;

export function WebSearchModelOptionsHost({ shot }: { shot: WebSearchModelOptionsShot }) {
  const [webPreference, setWebPreference] = useState<'off' | 'automatic' | 'force'>(shot.webPreference);
  return (
    <div style={COMPOSER_FRAME}>
      <div style={COMPOSER_BOX}>
        <ModelOptionsPopover
          provider={shot.provider}
          model={shot.model}
          webControl={shot.webControl}
          webPreference={webPreference}
          onWebPreferenceChange={setWebPreference}
          reasoningControl={shot.reasoningControl}
          reasoningIntent={shot.reasoningIntent}
          transportIdentity="shots"
          externalSearchSource={shot.externalSearchSource}
          {...(shot.initialPane ? { initialPane: shot.initialPane } : {})}
          // The shots never open the connect sheet; the callback exists only so "one-tap enable / Add search service" appear per production rules.
          onOpenSearchServiceSheet={() => {}}
          onClose={() => {}}
        />
      </div>
    </div>
  );
}
