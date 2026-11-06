# Simulation report

> **Simulation.** Share-button saves and DMs to @sous are simulated. In the Sous app, the recipe-writing step runs on the Sous server through the Claude API; here it was done by Claude Code.

## Stage 1: saves arriving

- 37 saves from 4 people: 19 by share button (main path), 18 by DM to @sous
- 1 duplicate (same person, same post): "Already in your recipes"
- 2 posts arrived by both paths and still map to one post
- 36 library entries, pointing at **33 unique posts**
- 3 posts were sent by more than one person, fetched and extracted once each

## Stage 2: posts → recipes

- Fetched without a login: 33 of 33
- Extracted: 33 (by claude-code-handoff (simulation): 33)

| Outcome | Posts |
|---|---|
| ✅ Recipe | 24 |
| 🔒 Recipe not reachable | 4 |
| ⚪ No recipe in post | 4 |
| ⏭️ Meal prep, skipped | 1 |

Where the recipes came from:

| Source | Recipes |
|---|---|
| caption | 13 |
| recipe page | 5 |
| video audio | 5 |
| video frames | 1 |

| Completeness | Recipes |
|---|---|
| complete | 19 |
| partial | 4 |
| estimated | 1 |

## Every post

| Post | Chef | Outcome | From | Reason |
|---|---|---|---|---|
| [Weekly Family Menu: Five Make-Ahead Meals](https://www.instagram.com/reel/DfHya3HsegL/) | @barefoodtim | ⏭️ Meal prep, skipped | — | The post is a weekly plan bundling five dishes, and the recipes themselves are only sent by DM after commenting 'PLAN'; neither caption nor audio contains a recipe. |
| [Slow-Cooked Beef Ragu Pappardelle](https://www.instagram.com/p/DZSnMAqtbRN/) | @kierans__kitchen | ⚪ No recipe in post | — | The caption only describes the dish with no quantities or method, and there is no recipe page, audio or frames. |
| [Blueberry Cheesecake Bites](https://www.instagram.com/reel/DfPrpAzOmfI/) | @amauryguichon | ⚪ No recipe in post | — | A silent pastry showpiece video with a short caption and no ingredients or quantities; the frames only show moulded blueberry cheesecake bites and a sculpted chocolate piece, not a recipe. |
| [Chocolate Jack Skellington](https://www.instagram.com/reel/De9gs1YOjOV/) | @amauryguichon | ⚪ No recipe in post | — | This is a chocolate sculpture showpiece; the caption only names the character and the audio is song lyrics, so there is no recipe. |
| [Homer's Doughnuts](https://www.instagram.com/reel/DeZf8flO9zT/) | @amauryguichon | ⚪ No recipe in post | — | This is a silent chocolate showpiece video of Homer's doughnuts; the caption and frames show the sculpture being built but give no recipe. |
| [Banana Coconut Cookies with Chocolate Drizzle](https://www.instagram.com/reel/DTwZpo5DNVr/) | @feelgoodfoodie | ✅ Recipe | caption | The caption contains a full ingredient list and method, so the caption was used. |
| [Stuffed Onions](https://www.instagram.com/reel/DVKgkKPDCjr/) | @feelgoodfoodie | ✅ Recipe | recipe page | The caption asks viewers to comment for the recipe, but it also links the recipe page, which contains the full recipe and was used. |
| [Zucchini Brownies](https://www.instagram.com/reel/DfORo6hRYny/) | @feelgoodfoodie | ✅ Recipe | recipe page | The linked recipe page has the full ingredients and method, so it was used rather than the brief audio summary. |
| [Greek Lemon Chicken and Potatoes with Greek Salad](https://www.instagram.com/reel/De-ZeM9POHt/) | @sivanskitchen | ✅ Recipe | caption | The caption contains the full recipe for the chicken, potatoes, salad and dressing, so the printable recipe offered by DM is not needed; the audio matches it. |
| [Chicken & Puff Pastry Pie](https://www.instagram.com/reel/DdJLdRwOkZ3/) | @fromscratchwithbob | ✅ Recipe | caption | The caption contains a full ingredient list and method for the pie; the audio is mostly a birthday story and only confirms the same steps. |
| [English Muffins](https://www.instagram.com/reel/DclEvxoORVU/) | @fromscratchwithbob | ✅ Recipe | caption | The caption contains a full English muffin recipe; the audio is a day-of-meals story with no quantities, so the caption was used. |
| [Fruit Crumble](https://www.instagram.com/reel/Da2OSYjOvrB/) | @fromscratchwithbob | ✅ Recipe | caption | The caption contains a full crumble recipe; the audio is mostly a reflective story about a day of cooking, so the caption was used. |
| [Sheet Pan Beef Kebabs with Roasted Vegetables and Fluffy White Rice](https://www.instagram.com/reel/Depy8xmvEGE/) | @sivanskitchen | ✅ Recipe | caption | Despite the 'Comment LINK' prompt, the caption contains the full kebab and rice recipe with method; quantities for the roasted vegetables are not given. |
| [General's Chicken](https://www.instagram.com/reel/DehfZkuJzyt/) | @barefoodtim | ✅ Recipe | caption | The caption contains a full ingredient list and method for the sauce and chicken; the audio is an ad-style story with no extra method, so the caption was used. |
| [Robuchon-Style Mashed Potatoes](https://www.instagram.com/reel/DY7at0aNs4S/) | @nick.digiovanni | ✅ Recipe | video audio | The caption is only a title, but the audio describes the full method with quantities, so the spoken method was used. |
| [Everything Sauce](https://www.instagram.com/reel/DZISw_yNLQq/) | @nick.digiovanni | ✅ Recipe | video audio | The caption is only a title, but the audio lists every ingredient with quantities and the method, so the spoken method was used. |
| [Crispy Chicken Skin Chips](https://www.instagram.com/reel/DYpZA9INHng/) | @nick.digiovanni | ✅ Recipe | video audio | The caption is only a title, but the audio describes the full method, so the spoken method was used; the amount of chicken skin is not given. |
| [Easy Pot Roast Stroganoff](https://www.instagram.com/reel/DfI_BlsBHj8/) | @halfbakedharvest | ✅ Recipe | recipe page | The linked recipe page on the creator's website has the full ingredients and method, so it was used. |
| [Creamy Chicken, Leek and Pancetta Pie](https://www.instagram.com/reel/DeruSjcoJvE/) | @emthenutritionist | ✅ Recipe | caption | The caption gives the full ingredient list and method; the audio is mostly an ad read for the pan, so the caption was used. |
| ['Heal Me' Chicken Soup](https://www.instagram.com/reel/DewzcpmoEDP/) | @emthenutritionist | ✅ Recipe | caption | The caption contains a full ingredient list and method; the audio only adds serving suggestions. |
| [15-Minute Harissa Lamb Flatbread](https://www.instagram.com/reel/Ddq5-XZtHAo/) | @kierans__kitchen | ✅ Recipe | video frames | The caption lists the components with no quantities or method, and the silent video's frames only show the finished flatbread, so the assembly order is reconstructed from the frames. |
| [Crispy Chicken Cutlet Focaccia Sandwiches](https://www.instagram.com/reel/DeHaGZ2On6H/) | @barefoodtim | ✅ Recipe | video audio | The caption has no recipe and the audio is mostly an olive oil ad and a story, but it does briefly describe the method, so a partial recipe is taken from the spoken steps. |
| [Chilli-Loaded Baked Potatoes](https://www.instagram.com/reel/DfTG7aHv1Wn/) | @sivanskitchen | ✅ Recipe | caption | The caption contains the full recipe with quantities and numbered instructions, so it was used directly. |
| [Crispy Chicken Shawarma](https://www.instagram.com/reel/DfVr002PvI-/) | @sivanskitchen | ✅ Recipe | caption | The caption contains the full recipe for the shawarma and its sides with quantities and numbered instructions, so it was used. |
| [Salmon and Crab Sushi Bake](https://www.instagram.com/reel/DfU2Kq3JyMR/) | @barefoodtim | ✅ Recipe | video audio | The caption has no recipe and the narration is largely a sponsored story, but the audio does outline the ingredients and layering method, so a partial recipe was written from the audio. |
| [Homemade Apple Focaccia Fritters](https://www.instagram.com/reel/DfQ0z7wB0Wv/) | @halfbakedharvest | ✅ Recipe | recipe page | The caption links to the full recipe page, which gives complete ingredients and method, so the blog was used. |
| [Spinach and Artichoke Dip Rolls](https://www.instagram.com/reel/DfV_arWgXno/) | @halfbakedharvest | ✅ Recipe | recipe page | The caption links to the full recipe page, which gives complete ingredients and method, so the blog was used. |
| [Maple Banana and Pecan Egg White Oats](https://www.instagram.com/reel/DfXpO7TokQv/) | @emthenutritionist | ✅ Recipe | caption | The caption contains the full recipe with quantities and method; the audio is nutrition opinion rather than method, so it was ignored. |
| [Mini Cranberry Meatballs](https://www.instagram.com/reel/DfVUc7PB1dv/) | @buzzfeedtasty | ✅ Recipe | caption | The caption contains the full ingredient list and method (only an optional slow-cooker note at the end is cut off), so it was used; the audio has no method. |
| [Hot Chocolate Rice Crispy Treats](https://www.instagram.com/reel/DeZf0saOjLB/) | @barefoodtim | 🔒 Recipe not reachable | video audio | The caption says the recipe is sent by DM after commenting a keyword, and the audio (mostly a sponsored story) only sketches the method without quantities. |
| [Minted Lamb Hotpot](https://www.instagram.com/p/DdoQSMHtasl/) | @kierans__kitchen | 🔒 Recipe not reachable | — | The caption says the recipe is in the comments, which are not available, and the caption itself only describes the dish. |
| [Plum Upside-Down Sweet Potato Cake](https://www.instagram.com/reel/DfX5SSihhfM/) | @buzzfeedtasty | 🔒 Recipe not reachable | — | The caption says the full recipe is at the link in bio, which isn't available, and the audio only praises the cake and names a few flavours without quantities or method. |
| [Vegan Fruit Jelly Cake](https://www.instagram.com/reel/DfVDUdOhvKe/) | @buzzfeedtasty | 🔒 Recipe not reachable | caption + audio | The caption says the full recipe is at the link in bio, which isn't available; the caption and audio only give an outline without quantities. |
