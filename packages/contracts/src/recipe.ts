import recipeSchema from "../schemas/recipe.schema.json";

export { recipeSchema };

export interface Recipe {
  id?: string;
  slug?: string;
  title: string;
  source_url?: string;
  servings?: number;
  times?: RecipeTimes;
  ingredients: Ingredient[];
  steps: Step[];
  created_at?: string;
  updated_at?: string;
}

export interface RecipeTimes {
  prep_minutes?: number;
  cook_minutes?: number;
  total_minutes?: number;
}

export interface Ingredient {
  name: string;
  quantity?: number;
  unit?: string;
  note?: string;
}

export interface Step {
  text: string;
  done_cue?: string;
  duration_seconds?: number;
}
