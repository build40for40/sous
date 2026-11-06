import { HttpError, isPlainObject } from "./http";

export const USER_MD = "USER.md";

export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };
export type Preferences = { [key: string]: JsonValue };

export interface Profile {
  preferences: Preferences;
  about: string;
  updated_at: string;
}

export interface ProfilePatch {
  preferences?: Preferences;
  about?: string;
}

const MAX_ABOUT = 20_000;
const MAX_PREFERENCES_BYTES = 16_384;

export function parseProfilePatch(input: unknown): ProfilePatch {
  if (!isPlainObject(input)) throw new HttpError(400, "invalid_profile", { message: "Send a JSON object." });
  const unknownKeys = Object.keys(input).filter((k) => k !== "preferences" && k !== "about");
  if (unknownKeys.length) throw new HttpError(400, "invalid_profile", { message: `Unknown fields: ${unknownKeys.join(", ")}.` });
  const patch: ProfilePatch = {};
  if ("preferences" in input) {
    if (!isPlainObject(input.preferences)) throw new HttpError(400, "invalid_profile", { message: "preferences must be an object." });
    patch.preferences = input.preferences as Preferences;
  }
  if ("about" in input) {
    if (typeof input.about !== "string" || input.about.length > MAX_ABOUT) {
      throw new HttpError(400, "invalid_profile", { message: `about must be text up to ${MAX_ABOUT} characters.` });
    }
    patch.about = input.about;
  }
  return patch;
}

export function applyPreferences(current: Preferences, changes: Preferences): Preferences | null {
  const next: Preferences = { ...current };
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) delete next[key];
    else next[key] = value;
  }
  return new TextEncoder().encode(JSON.stringify(next)).byteLength > MAX_PREFERENCES_BYTES ? null : next;
}
