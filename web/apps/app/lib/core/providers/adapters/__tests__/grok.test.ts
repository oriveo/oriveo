import { describe, expect, it } from "vitest";
import * as grok from "../grok";

describe("grok adapter", () => {
  it("exports validateKey, syncModels, sendMessageStream", () => {
    expect(typeof grok.validateKey).toBe("function");
    expect(typeof grok.syncModels).toBe("function");
    expect(typeof grok.sendMessageStream).toBe("function");
  });
});
