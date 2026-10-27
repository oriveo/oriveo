'use client';

// Current value of the "Web search" cell on the settings home: the default service's display name; no service = null (shows "Not set"); loading = undefined.

import { createContext, useContext, useEffect, useState } from 'react';
import { resolveDefaultSearchService } from '@oriveo/core/search/search-settings';
import { getActiveUID } from '../infra/storage/partition';
import { getDefaultSearchServiceId, listSearchServices } from './search-service-store';
import { loadSettingsCatalog, serviceDisplayName } from './search-settings-data';

/** Value injected into the home cell by dev sample renders (not provided in production; read from the local store). */
export const WebSearchEntryOverride = createContext<{ name: string | null } | null>(null);

export function useWebSearchDefaultName(): string | null | undefined {
  const override = useContext(WebSearchEntryOverride);
  const [name, setName] = useState<string | null | undefined>(undefined);
  useEffect(() => {
    if (override) return;
    let cancelled = false;
    void (async () => {
      try {
        const uid = await getActiveUID();
        const [records, storedDefault] = await Promise.all([listSearchServices(uid), getDefaultSearchServiceId(uid)]);
        const services = records.filter((r) => !r.pendingAdd);
        const defaultId = resolveDefaultSearchService({ serviceIds: services.map((s) => s.id), storedDefault });
        const service = services.find((s) => s.id === defaultId) ?? null;
        if (!service) {
          if (!cancelled) setName(null);
          return;
        }
        const catalog = service.kind === 'preset' ? await loadSettingsCatalog() : null;
        if (!cancelled) setName(serviceDisplayName(catalog, service));
      } catch {
        if (!cancelled) setName(null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [override]);
  return override ? override.name : name;
}
