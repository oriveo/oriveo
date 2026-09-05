import fs from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const cacheMarkers: Record<string, string> = {
  ar: "مؤقت",
  de: "Cache",
  en: "cache",
  es: "caché",
  fr: "cache",
  hi: "कैश",
  id: "Cache",
  ja: "キャッシュ",
  ko: "캐시",
  "pt-BR": "cache",
  ru: "кэш",
  th: "แคช",
  tr: "önbellek",
  vi: "Bộ nhớ đệm",
  "zh-Hans": "\u7f13\u5b58",
  "zh-Hant": "\u5feb\u53d6",
};

describe("Library privacy localization", () => {
  it("all 16 locales disclose the short-lived request cache", () => {
    const messagesDir = path.resolve(__dirname, "../../../messages");
    for (const [locale, marker] of Object.entries(cacheMarkers)) {
      const messages = JSON.parse(
        fs.readFileSync(path.join(messagesDir, `${locale}.json`), "utf8"),
      ) as { library?: { privacyDescription?: string } };
      const copy = messages.library?.privacyDescription ?? "";
      expect(copy, `${locale} must disclose caching`).toContain(marker);
    }
  });

  it("all 16 locales disclose that disconnecting Oriveo does not revoke Notion-side authorization", () => {
    const messagesDir = path.resolve(__dirname, "../../../messages");
    for (const locale of Object.keys(cacheMarkers)) {
      const messages = JSON.parse(
        fs.readFileSync(path.join(messagesDir, `${locale}.json`), "utf8"),
      ) as { library?: { disconnectMessage?: string } };
      const copy = messages.library?.disconnectMessage ?? "";
      expect(copy, `${locale} must mention Notion`).toContain("Notion");
      expect(copy, `${locale} must mention Oriveo`).toContain("Oriveo");
    }
  });
});
