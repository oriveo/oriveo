'use client';

import { useEffect, useMemo, useState } from 'react';
import { AddSearchServiceSheet, type AddSheetInitial } from '../../app/settings/web-search/AddSearchServiceSheet';
import { useAppStore } from '../../providers/StoreProvider';
import { searchConnectionsFromProviders, serviceDisplayName } from '../../lib/search/search-settings-data';
import { getConversationSearchSource, listSearchServices } from '../../lib/search/search-service-store';
import {
  loadExternalSearchData,
  notifySearchServicesChanged,
  readDraftSearchSource,
  writeConversationSearchSource,
  type ExternalSearchData,
} from '../../lib/search/external-search-context';

/**
 * "Add search service" embedded in the chat page: the same onboarding sheet as in settings, opened in place;
 * after it closes the draft and conversation are untouched (the chat page is never left) and the host returns to the model options panel.
 * - One-tap enable: starts from the onboarding step 4, prefilled with the reused connection and site; from the web card's "Add search service": starts from the picker page.
 * - With `arm` (oneTapArms), a successful save sends pick_service for the new service = turns external search on for this conversation x this model; conversation web is not written.
 */
export type ChatSearchServiceSheetRequest = {
  initial: AddSheetInitial;
  arm?: { modelKey: string; knownServiceIds: readonly string[]; conversationId?: string; draftSessionId?: string };
};

/** Save succeeded: find the newly stored service (not in the list from before opening) and send pick_service. */
async function armSavedService(uid: string, catalog: ExternalSearchData['catalog'], arm: NonNullable<ChatSearchServiceSheetRequest['arm']>): Promise<void> {
  const known = new Set(arm.knownServiceIds);
  const saved = (await listSearchServices(uid))
    .filter((record) => !known.has(record.id) && !record.pendingAdd)
    .sort((a, b) => b.createdAt - a.createdAt)[0];
  if (!saved) return;
  const stored = arm.conversationId
    ? await getConversationSearchSource(uid, arm.conversationId)
    : arm.draftSessionId ? readDraftSearchSource(arm.draftSessionId) : null;
  await writeConversationSearchSource({
    uid,
    conversationId: arm.conversationId,
    ...(arm.draftSessionId ? { draftSessionId: arm.draftSessionId } : {}),
    stored,
    modelKey: arm.modelKey,
    event: { type: 'pick_service', serviceId: saved.id, serviceName: serviceDisplayName(catalog, saved) },
  });
}

export function ChatSearchServiceSheet({
  request,
  onClose,
}: {
  request: ChatSearchServiceSheetRequest;
  /** Reached only after the test passes and the user taps Done, or the user cancels (on failure the sheet stays to show the reason and allow changing the key / retrying); the host returns to the model options panel. */
  onClose: () => void;
}) {
  const providers = useAppStore((s) => s.providers);
  const connections = useMemo(() => searchConnectionsFromProviders(providers ?? []), [providers]);
  const [data, setData] = useState<ExternalSearchData | null>(null);

  useEffect(() => {
    let cancelled = false;
    void loadExternalSearchData(connections).then((loaded) => {
      if (!cancelled) setData(loaded);
    }, () => {});
    return () => {
      cancelled = true;
    };
  }, [connections]);

  if (!data) return null;
  return (
    <AddSearchServiceSheet
      initial={request.initial}
      open
      onClose={onClose}
      uid={data.uid}
      catalog={data.catalog}
      connections={data.connections}
      services={data.snapshot.services}
      onSaved={() => {
        const arm = request.arm;
        void (arm ? armSavedService(data.uid, data.catalog, arm).catch(() => {}) : Promise.resolve()).then(() => {
          notifySearchServicesChanged();
        });
      }}
      // An already-added service does not jump to details in chat: close the sheet and return to model options.
      onOpenService={() => onClose()}
    />
  );
}
