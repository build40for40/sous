import type { Rating } from "./reflection";
import { londonDate } from "./vault";

export const MAX_HISTORY = 200;

export type CookReflectionStatus = "pending" | "done" | "failed";

export interface Cook {
  session_id: string;
  recipe_id: string | null;
  recipe_title: string | null;
  started_at: string;
  ended_at: string;
  date: string;
  rating: Rating | null;
  summary: string | null;
  reflection_status: CookReflectionStatus;
}

interface CookRow extends Record<string, SqlStorageValue> {
  id: string;
  recipe_id: string | null;
  recipe_title: string | null;
  started_at: string;
  ended_at: string;
  rating: number | null;
  summary: string | null;
  reflected_at: string | null;
  reflection_error: string | null;
}

/** Every finished cook, newest first. The rating is the cook's own, or the reflection's read of it when they gave none. */
export function listCooks(sql: SqlStorage): Cook[] {
  return sql
    .exec<CookRow>(
      `SELECT s.id, s.recipe_id, r.title AS recipe_title, s.started_at, s.ended_at,
              COALESCE(s.rating, json_extract(s.reflection, '$.rating')) AS rating,
              json_extract(s.reflection, '$.summary') AS summary,
              s.reflected_at, s.reflection_error
       FROM sessions s LEFT JOIN recipes r ON r.id = s.recipe_id
       WHERE s.ended_at IS NOT NULL
       ORDER BY s.started_at DESC, s.rowid DESC
       LIMIT ?`,
      MAX_HISTORY,
    )
    .toArray()
    .map((row) => ({
      session_id: row.id,
      recipe_id: row.recipe_id,
      recipe_title: row.recipe_title,
      started_at: row.started_at,
      ended_at: row.ended_at,
      date: londonDate(row.started_at),
      rating: row.rating as Rating | null,
      summary: row.summary,
      reflection_status: row.reflected_at ? "done" : row.reflection_error ? "failed" : "pending",
    }));
}
