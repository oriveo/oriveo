import { describe, expect, it } from "vitest";
import { extractLibrarySourceMentions } from "./source-mentions";

describe("extractLibrarySourceMentions", () => {
  it.each([
    ["@Notion summarize the roadmap", ["notion"]],
    ["Compare @Google Docs with @Notion", ["google", "notion"]],
    ["Take a look at @Google Drive, find the pricing plan", ["google"]],
    ["ask @google about this", ["google"]],
  ])("extracts supported mentions from %s", (text, expected) => {
    expect(extractLibrarySourceMentions(text)).toEqual(expected);
  });

  it.each([
    "mail me at user@notion.so",
    "the @notional plan",
    "@Notes is not a scheduled Library source",
  ])("does not infer a Library source from %s", (text) => {
    expect(extractLibrarySourceMentions(text)).toEqual([]);
  });
});
