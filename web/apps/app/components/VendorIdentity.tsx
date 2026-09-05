"use client";

import Image from "next/image";
import { type CSSProperties } from "react";
import { useIsDarkTheme } from "../lib/hooks/useIsDarkTheme";
import { resolveOfficialVendorLogo } from "./provider-logo-assets";
import styles from "./VendorIdentity.module.css";

type VendorFrameMode = "adaptive" | "light" | "dark";
type VendorFrameTone = "neutral" | "warm";

interface VendorVisualConfig {
  logo: string;
  darkLogo?: string;
  padding?: number;
  paddingX?: number;
  paddingY?: number;
  scale?: number;
  offsetX?: number;
  offsetY?: number;
  frameMode?: VendorFrameMode;
  frameTone?: VendorFrameTone;
}

interface VendorPresentation {
  background: string;
  darkBackground: string;
  border: string;
  darkBorder: string;
  foreground: string;
  darkForeground: string;
}

const VENDOR_VISUALS: Record<string, VendorVisualConfig> = {
  meta: {
    logo: "/providers/vendors/meta.png",
    paddingX: 0.17,
    paddingY: 0.11,
    scale: 1.04,
  },
  mistral: {
    logo: "/providers/vendors/mistral.png",
    paddingX: 0.17,
    paddingY: 0.17,
  },
  perplexity: {
    logo: "/providers/vendors/perplexity.png",
    paddingX: 0.18,
    paddingY: 0.17,
    scale: 0.96,
  },
  cohere: {
    logo: "/providers/vendors/cohere.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  microsoft: {
    logo: "/providers/vendors/microsoft.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  nvidia: {
    logo: "/providers/vendors/nvidia.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  bytedance: {
    logo: "/providers/vendors/bytedance.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  stepfun: {
    logo: "/providers/vendors/stepfun.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  upstage: {
    logo: "/providers/vendors/upstage.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  aionlabs: {
    logo: "/providers/vendors/aionlabs.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  baidu: {
    logo: "/providers/vendors/baidu.png",
    paddingX: 0.17,
    paddingY: 0.17,
    frameMode: "light",
  },
  ai2: { logo: "/providers/vendors/ai2.png", paddingX: 0.18, paddingY: 0.18 },
  arcee: {
    logo: "/providers/vendors/arcee.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  cerebras: {
    logo: "/providers/vendors/cerebras.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  sambanova: {
    logo: "/providers/vendors/sambanova.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  huggingface: {
    logo: "/providers/vendors/huggingface.png",
    paddingX: 0.17,
    paddingY: 0.17,
  },
  alibaba: {
    logo: "/providers/vendors/alibaba.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  deepcogito: {
    logo: "/providers/vendors/deepcogito.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  essentialai: {
    logo: "/providers/vendors/essentialai.png",
    paddingX: 0.17,
    paddingY: 0.17,
    frameMode: "light",
  },
  kwaipilot: {
    logo: "/providers/vendors/kwaipilot.png",
    paddingX: 0.16,
    paddingY: 0.16,
    frameMode: "dark",
  },
  morph: {
    logo: "/providers/vendors/morph.png",
    paddingX: 0.16,
    paddingY: 0.16,
    frameMode: "dark",
  },
  tencent: {
    logo: "/providers/vendors/tencent.png",
    paddingX: 0.17,
    paddingY: 0.17,
    frameMode: "light",
  },
  aws: {
    logo: "/providers/vendors/aws.png",
    paddingX: 0.15,
    paddingY: 0.08,
    scale: 1.05,
    frameMode: "light",
  },
  ai21: {
    logo: "/providers/vendors/ai21.png",
    darkLogo: "/providers/vendors/ai21-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  nousresearch: {
    logo: "/providers/vendors/nousresearch.png",
    darkLogo: "/providers/vendors/nousresearch-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  inflection: {
    logo: "/providers/vendors/inflection.png",
    darkLogo: "/providers/vendors/inflection-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  xiaomi: {
    logo: "/providers/vendors/xiaomi.png",
    darkLogo: "/providers/vendors/xiaomi-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  liquid: {
    logo: "/providers/vendors/liquid.png",
    darkLogo: "/providers/vendors/liquid-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  manus: {
    logo: "/providers/vendors/manus.png",
    darkLogo: "/providers/vendors/manus-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  relace: {
    logo: "/providers/vendors/relace.png",
    darkLogo: "/providers/vendors/relace-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  ibm: {
    logo: "/providers/vendors/ibm.png",
    darkLogo: "/providers/vendors/ibm-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
  inception: {
    logo: "/providers/vendors/inception.png",
    darkLogo: "/providers/vendors/inception-dark.png",
    paddingX: 0.18,
    paddingY: 0.18,
  },
};

interface VendorIdentityProps {
  groupId: string;
  title: string;
  small?: boolean;
  density?: "default" | "compact";
  dataTestId?: string;
}

export function VendorIdentity({
  groupId,
  title,
  small = false,
  density = "default",
  dataTestId,
}: VendorIdentityProps) {
  const isDark = useIsDarkTheme();
  const normalizedKey = normalizeVendorKey(groupId);
  const visual = getVendorVisual(normalizedKey);
  const officialLogo = resolveOfficialVendorLogo(normalizedKey, isDark);
  const logoSrc = officialLogo ?? (isDark && visual?.darkLogo ? visual.darkLogo : visual?.logo);
  const presentation = getVendorBadgePresentation(groupId, Boolean(visual));
  const frameSize = density === "compact" ? (small ? 26 : 38) : (small ? 30 : 42);
  const paddingX = officialLogo ? 0 : (visual?.paddingX ?? visual?.padding ?? 0.18);
  const paddingY = officialLogo ? 0 : (visual?.paddingY ?? visual?.padding ?? 0.18);
  const monogram =
    title
      .split(/[^a-zA-Z0-9]+/)
      .filter(Boolean)
      .slice(0, 2)
      .map((chunk) => chunk[0]?.toUpperCase())
      .join("") || title.slice(0, 2).toUpperCase();

  return (
    <span
      className={styles.vendorIdentity}
      data-small={small}
      data-density={density}
      data-dark={isDark}
      data-frame-mode={officialLogo ? "adaptive" : visual?.frameMode ?? "adaptive"}
      data-has-logo={Boolean(logoSrc)}
      data-testid={dataTestId}
      style={
        {
          "--vendor-frame-bg": isDark
            ? presentation.darkBackground
            : presentation.background,
          "--vendor-frame-border": isDark
            ? presentation.darkBorder
            : presentation.border,
          "--vendor-frame-fg": isDark
            ? presentation.darkForeground
            : presentation.foreground,
          "--vendor-logo-padding-x": `${Math.round(frameSize * paddingX)}px`,
          "--vendor-logo-padding-y": `${Math.round(frameSize * paddingY)}px`,
          "--vendor-logo-scale": String(visual?.scale ?? 1),
          "--vendor-logo-shift-x": `${Math.round(frameSize * (visual?.offsetX ?? 0))}px`,
          "--vendor-logo-shift-y": `${Math.round(frameSize * (visual?.offsetY ?? 0))}px`,
        } as CSSProperties
      }
      aria-hidden="true"
    >
      {logoSrc ? (
        <Image
          className={styles.vendorLogo}
          src={logoSrc}
          alt=""
          width={frameSize}
          height={frameSize}
          draggable={false}
        />
      ) : (
        <span className={styles.vendorMonogram}>{monogram}</span>
      )}
    </span>
  );
}

function getVendorVisual(groupId: string): VendorVisualConfig | null {
  return VENDOR_VISUALS[normalizeVendorKey(groupId)] ?? null;
}

export function getVendorBadgePresentation(
  groupId: string,
  hasVisual: boolean,
): VendorPresentation {
  const normalized = normalizeVendorKey(groupId);
  const visual = getVendorVisual(normalized);
  if (visual) {
    return buildFixedVendorPresentation(
      visual.frameMode ?? "adaptive",
      visual.frameTone ?? "neutral",
    );
  }

  const hue = hashHue(normalized);
  if (hasVisual) {
    return buildFixedVendorPresentation("adaptive", "neutral");
  }

  return {
    background: `hsl(${hue} 55% 96%)`,
    darkBackground: `hsl(${hue} 24% 20%)`,
    border: `hsl(${hue} 32% 82%)`,
    darkBorder: `hsl(${hue} 24% 32%)`,
    foreground: `hsl(${hue} 55% 34%)`,
    darkForeground: `hsl(${hue} 70% 74%)`,
  };
}

function buildFixedVendorPresentation(
  frameMode: VendorFrameMode,
  frameTone: VendorFrameTone,
): VendorPresentation {
  if (frameMode === "dark") {
    return {
      background: "#1f2530",
      darkBackground: "#1f2530",
      border: "#313949",
      darkBorder: "#3a4558",
      foreground: "#f8fafc",
      darkForeground: "#f8fafc",
    };
  }

  if (frameMode === "light") {
    if (frameTone === "warm") {
      return {
        background: "#f5efe4",
        darkBackground: "#f5efe4",
        border: "#e1d6c3",
        darkBorder: "#d7cab4",
        foreground: "#18181b",
        darkForeground: "#18181b",
      };
    }

    return {
      background: "#f7f8fa",
      darkBackground: "#f7f8fa",
      border: "#dde3eb",
      darkBorder: "#d2d9e3",
      foreground: "#0f172a",
      darkForeground: "#0f172a",
    };
  }

  return {
    background: "#f7f8fa",
    darkBackground: "#171c24",
    border: "#dde3eb",
    darkBorder: "#2d3644",
    foreground: "#0f172a",
    darkForeground: "#f8fafc",
  };
}

export function normalizeVendorKey(groupId: string): string {
  switch (groupId.toLowerCase()) {
    case "meta-llama":
    case "meta":
      return "meta";
    case "mistralai":
    case "mistral":
      return "mistral";
    case "together":
    case "togetherai":
      return "together";
    case "fireworks":
    case "fireworksai":
      return "fireworks";
    case "x-ai":
    case "xai-grok":
      return "xai";
    case "moonshotai":
    case "kimi":
      return "moonshot";
    case "google-gemini":
    case "gemini":
      return "google";
    case "aion-labs":
      return "aionlabs";
    case "allenai":
      return "ai2";
    case "arcee-ai":
      return "arcee";
    case "bytedance-seed":
    case "bytedance":
      return "bytedance";
    case "kwai":
    case "kwai-kolors":
      return "kwaipilot";
    case "deepseek-ai":
      return "deepseek";
    case "amazon":
      return "aws";
    case "ibm-granite":
      return "ibm";
    case "z-ai":
    case "zai-org":
    case "thudm":
    case "zhipu-glm":
    case "zhipu":
      return "zai";
    case "stepfun-ai":
      return "stepfun";
    case "nex-agi":
      return "nex-agi";
    default:
      return groupId.toLowerCase().replace(/[^a-z0-9]/g, "");
  }
}

function hashHue(value: string): number {
  let hash = 5381;
  for (const character of value) {
    hash = (hash << 5) + hash + character.charCodeAt(0);
  }
  return Math.abs(hash) % 360;
}
