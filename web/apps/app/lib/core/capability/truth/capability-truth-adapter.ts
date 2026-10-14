import type { AIModel, Provider } from '@oriveo/shared';
import type {
  CapabilityEvidenceCandidate,
  CapabilityEvidenceQuery,
} from '@oriveo/core/providers/capability-evidence-facade';

export type ModelCapabilityKey =
  | 'web_search'
  | 'vision_input'
  | 'tool_call'
  | `reasoning_level/${string}`;

export type RelayCapabilityEvidenceIdentity = Pick<CapabilityEvidenceQuery,
  'partitionId' | 'connectionInstanceId' | 'connectionGeneration' | 'credentialEpoch' | 'endpointFingerprint'>;

export interface CapabilityTruthQuery {
  provider: Provider;
  model: AIModel;
  /** The transport the production dispatcher will actually use; when `unknown`, facts bound to the transport are unavailable. */
  effectiveTransport: string;
  /** Consumed only by the Relay form: the connection-level identity is injected by the local producer; the adapter does not build it. */
  relayIdentity?: RelayCapabilityEvidenceIdentity;
  /** When omitted, means all candidates visible for this connection x model (e.g. to compute the earliest expiry). */
  key?: ModelCapabilityKey;
}

/**
  * The capability truth source of one form. An adapter only produces candidates and makes no rulings: priority, conflicts, expiry and explicit intent
  * are all handled by the shared facade, so adding a form does not add another set of criteria.
 */
export interface CapabilityTruthAdapter {
  /**
      * Whether "no candidate" in this form equals "nobody has verified it". Official / Relay are open-world: with no evidence
      * the user's explicit intent may allow it through. A hosted catalog is closed-world: what the catalog does not declare is not offered,
      * and explicit intent cannot turn that into an allow.
   */
  readonly acceptsUnverifiedExplicitIntent: boolean;
  /**
      * State 1 of catalog-type forms: when this form's snapshot has not been fetched yet and the key asked about is one the catalog governs,
      * the identity is incomplete and must fail closed, so even if the form itself is open-world, explicit intent cannot slip through on "no candidate".
      * Default (not implemented) means it never closes the gate.
   */
  failsClosed?(query: CapabilityTruthQuery): boolean;
  candidates(query: CapabilityTruthQuery): CapabilityEvidenceCandidate[];
}
