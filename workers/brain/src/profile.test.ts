import { describe, expect, it } from "vitest";
import { HttpError } from "./http";
import { applyPreferences, parseProfilePatch } from "./profile";

describe("parseProfilePatch", () => {
  it("accepts preferences and about", () => {
    expect(parseProfilePatch({ preferences: { units: "imperial" }, about: "hi" })).toEqual({ preferences: { units: "imperial" }, about: "hi" });
    expect(parseProfilePatch({})).toEqual({});
  });

  it.each([[[]], ["text"], [{ id: "user_x" }], [{ preferences: "spicy" }], [{ about: 5 }], [{ about: "x".repeat(20_001) }]])(
    "rejects %j",
    (input) => {
      expect(() => parseProfilePatch(input)).toThrow(HttpError);
    },
  );
});

describe("applyPreferences", () => {
  it("merges changes and removes null keys", () => {
    expect(applyPreferences({ units: "metric", avoid: [] }, { avoid: ["coriander"], units: null, spice: "hot" })).toEqual({
      avoid: ["coriander"],
      spice: "hot",
    });
  });

  it("refuses preferences over the size limit", () => {
    expect(applyPreferences({}, { notes: "x".repeat(20_000) })).toBeNull();
  });
});
