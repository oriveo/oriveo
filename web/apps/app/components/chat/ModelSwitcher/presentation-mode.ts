import type { AIModel, Provider } from "@oriveo/shared";

export type FilterKey =
  | "free"
  | "recommended"
  | "reasoning"
  | "image"
  | "file"
  | "web"
  | "imageGeneration";

export const CAPABILITY_FILTERS: Array<{ key: FilterKey; capability: string }> = [
  { key: "reasoning", capability: "reasoning" },
  { key: "image", capability: "image" },
  { key: "file", capability: "file" },
  { key: "web", capability: "web" },
  { key: "imageGeneration", capability: "imageGeneration" },
];

export const CATALOG_SHORTCUT_LIMIT = 8;

export type SwitcherView =
  | { kind: "browse" }
  | { kind: "catalog"; providerId: string }
  | { kind: "manual"; providerId: string };

export interface ProviderSection {
  provider: Provider;
  providerName: string;
  models: AIModel[];
  canAddModels: boolean;
}
