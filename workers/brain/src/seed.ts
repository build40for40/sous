import type { NewRecipe } from "./recipes";
import type { Preferences } from "./profile";

export const starterPreferences: Preferences = {
  units: "metric",
  diet: [],
  avoid: [],
};

export const starterAbout = `# About me

Sous fills this in as we cook together: what you love, what you won't touch, and how many pans you actually own.
`;

export const demoRecipe: NewRecipe = {
  title: "Fake Demo Cheese Toastie",
  source_url: "https://example.com/sous/fake-demo-cheese-toastie",
  servings: 1,
  times: { prep_minutes: 2, cook_minutes: 6, total_minutes: 8 },
  ingredients: [
    { name: "bread", quantity: 2, unit: "slices" },
    { name: "butter", quantity: 1, unit: "tbsp", note: "soft" },
    { name: "cheddar", quantity: 60, unit: "g", note: "grated" },
  ],
  steps: [
    { text: "Butter one side of each slice of bread.", done_cue: "Buttered edge to edge, no dry corners." },
    {
      text: "Sandwich the cheese between the slices, buttered sides out, and cook in a dry pan over a medium heat.",
      done_cue: "Deep golden underneath and the cheese starting to ooze.",
      duration_seconds: 180,
    },
    {
      text: "Flip it and cook the other side, then cut it in half and let it sit for a minute.",
      done_cue: "Both sides golden and the cheese fully melted.",
      duration_seconds: 180,
    },
  ],
};
