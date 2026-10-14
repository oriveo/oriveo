import type { CapabilityTruthAdapter } from './capability-truth-adapter';
import { officialTruthAdapter } from './official-truth-adapter';
import type { ProviderForm } from './provider-form';
import { relayTruthAdapter } from './relay-truth-adapter';
import { subscriptionTruthAdapter } from './subscription-truth-adapter';

/** The single mapping from form to capability truth adapter; consumers no longer branch on provider.kind themselves. */
export const capabilityTruthRegistry = {
  adapterFor(form: ProviderForm): CapabilityTruthAdapter {
    switch (form) {
      case 'relay':
        return relayTruthAdapter;
      case 'subscription':
        return subscriptionTruthAdapter;
      case 'official':
        return officialTruthAdapter;
      default: {
        // Adding a form without registering it here is a compile error, so it never silently falls onto some default adapter.
        const unhandled: never = form;
        throw new Error(`unhandled provider form: ${String(unhandled)}`);
      }
    }
  },
};
