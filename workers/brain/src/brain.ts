import { DurableObject } from "cloudflare:workers";
import type { Recipe } from "@sous/contracts";
import { applyPreferences, USER_MD, type Preferences, type Profile, type ProfilePatch } from "./profile";
import { fromRow, slugify, toRow, type NewRecipe, type RecipeRow } from "./recipes";
import { migrate } from "./schema";
import { demoRecipe, starterAbout, starterPreferences } from "./seed";

interface FileRow extends Record<string, SqlStorageValue> {
  frontmatter: string;
  body: string;
  updated_at: string;
}

export class UserBrain extends DurableObject<Env> {
  private ready = false;

  private get sql(): SqlStorage {
    return this.ctx.storage.sql;
  }

  private init(): void {
    if (this.ready) return;
    this.ctx.storage.transactionSync(() => {
      const now = new Date().toISOString();
      if (migrate(this.sql, now) === 0) this.seed(now);
    });
    this.ready = true;
  }

  private seed(now: string): void {
    this.writeUserMd(starterPreferences, starterAbout, now);
    this.insertRecipe(demoRecipe, now);
  }

  getProfile(): Profile {
    this.init();
    const row = this.sql.exec<FileRow>("SELECT frontmatter, body, updated_at FROM files WHERE path = ?", USER_MD).toArray()[0];
    if (!row) return { preferences: {}, about: "", updated_at: new Date(0).toISOString() };
    return { preferences: JSON.parse(row.frontmatter), about: row.body, updated_at: row.updated_at };
  }

  updateProfile(patch: ProfilePatch): Profile | null {
    const current = this.getProfile();
    const preferences = patch.preferences ? applyPreferences(current.preferences, patch.preferences) : current.preferences;
    if (!preferences) return null;
    this.writeUserMd(preferences, patch.about ?? current.about, new Date().toISOString());
    return this.getProfile();
  }

  async wipe(): Promise<void> {
    await this.ctx.storage.deleteAll();
    this.ready = false;
  }

  listRecipes(): Recipe[] {
    this.init();
    return this.sql.exec<RecipeRow>("SELECT * FROM recipes ORDER BY created_at DESC, rowid DESC").toArray().map(fromRow);
  }

  getRecipe(id: string): Recipe | null {
    this.init();
    const row = this.sql.exec<RecipeRow>("SELECT * FROM recipes WHERE id = ?", id).toArray()[0];
    return row ? fromRow(row) : null;
  }

  createRecipe(recipe: NewRecipe): Recipe {
    this.init();
    return this.insertRecipe(recipe, new Date().toISOString());
  }

  deleteRecipe(id: string): boolean {
    this.init();
    return this.sql.exec("DELETE FROM recipes WHERE id = ?", id).rowsWritten > 0;
  }

  private insertRecipe(recipe: NewRecipe, now: string): Recipe {
    const row = toRow(recipe, crypto.randomUUID(), this.uniqueSlug(slugify(recipe.title)), now);
    this.sql.exec(
      "INSERT INTO recipes (id, slug, source_url, title, data, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      row.id,
      row.slug,
      row.source_url,
      row.title,
      row.data,
      row.created_at,
      row.updated_at,
    );
    return fromRow(row);
  }

  private uniqueSlug(base: string): string {
    const taken = (slug: string) => this.sql.exec("SELECT 1 FROM recipes WHERE slug = ?", slug).toArray().length > 0;
    let slug = base;
    for (let n = 2; taken(slug); n++) slug = `${base}-${n}`;
    return slug;
  }

  private writeUserMd(preferences: Preferences, about: string, now: string): void {
    this.sql.exec(
      `INSERT INTO files (path, kind, frontmatter, body, updated_at) VALUES (?, 'user', ?, ?, ?)
       ON CONFLICT (path) DO UPDATE SET frontmatter = excluded.frontmatter, body = excluded.body, updated_at = excluded.updated_at`,
      USER_MD,
      JSON.stringify(preferences),
      about,
      now,
    );
  }
}
