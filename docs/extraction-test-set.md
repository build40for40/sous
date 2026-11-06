# Extraction test set

Real Instagram posts, one or more per format, for testing recipe extraction. Verified on 6 November 2026: captions fetched with yt-dlp 2026.10.26 (videos) or the public embed page (photos), audio transcribed locally with faster-whisper `small`, frames sampled at four points, comments read in a signed-in browser.

"Narrated" means speech was detected in the audio. "On-screen text" means recipe text burned into the video, not subtitles of the narration.

| # | Format | Creator | Post | Narrated | On-screen recipe text | Caption | Where the recipe is |
|---|---|---|---|---|---|---|---|
| 1 | Narrated + full recipe in caption | @feelgoodfoodie | [banana coconut cookies](https://www.instagram.com/feelgoodfoodie/reel/DTwZpo5DNVr/) | Yes, method | No | Ingredients + numbered steps | Caption (and audio) |
| 2 | Narrated + full recipe in caption | @barefoodtim | [General's Chicken](https://www.instagram.com/barefoodtim/reel/DehfZkuJzyt/) | Yes, method + chat | No | Ingredients + method (#ad) | Caption |
| 3 | Narration is a story, recipe in caption | @fromscratchwithbob | [chicken & puff pastry pie](https://www.instagram.com/fromscratchwithbob/reel/DdJLdRwOkZ3/) | Yes, childhood story | No | "Recipe below 👇" then full recipe | Caption only. Audio is noise |
| 4 | Narration is an opinion piece, recipe in caption | @emthenutritionist | [maple banana egg white oats](https://www.instagram.com/emthenutritionist/reel/DfXpO7TokQv/) | Yes, nutrition rant | Subtitles only | Full recipe with kcal/protein | Caption only. Audio is noise |
| 5 | Narrated method, title-only caption | @barefoodtim | [sushi bake](https://www.instagram.com/barefoodtim/reel/DfU2Kq3JyMR/) | Yes, method | Subtitles only | Dish name + sponsor | Audio only |
| 6 | Narrated method, title-only caption | @nick.digiovanni | [3-Michelin star potatoes](https://www.instagram.com/nick.digiovanni/reel/DY7at0aNs4S/) | Yes, method with quantities | No | Dish name | Audio only |
| 7 | "Comment HBH" → DM, blog URL in caption | @halfbakedharvest | [apple focaccia fritters](https://www.instagram.com/halfbakedharvest/reel/DfQ0z7wB0Wv/) | Yes, loose method | No | Teaser + keyword + blog URL | Blog (best), DM, audio (partial) |
| 8 | "Comment RECIPE" → DM, blog URL in caption | @feelgoodfoodie | [stuffed onions](https://www.instagram.com/feelgoodfoodie/reel/DVKgkKPDCjr/) | Yes, description | No | Teaser + keyword + blog URL | Blog (best), DM |
| 9 | "Comment LINK" → DM, no URL in caption | @sivanskitchen | [loaded baked potato](https://www.instagram.com/sivanskitchen/reel/DfTG7aHv1Wn/) | Yes, method with quantities | No | Teaser + keyword | Audio (good), DM |
| 10 | Silent + full recipe in caption | Iram Mansoor | [crispy cheesy hashbrowns](https://www.instagram.com/p/DdCZphFy2SU/) (8.3M likes) | No | Title only | Ingredients + method | Caption |
| 11 | Silent + bilingual caption | Buse Zeynep | [crispy lavash cones](https://www.instagram.com/p/DVLi8q6iPks/) (3.5M likes) | No | No | Turkish, then English | Caption (pick the English half) |
| 12 | Silent, title only, no recipe anywhere | Silent Gourmet ASMR | [vegetable egg rice](https://www.instagram.com/p/DeT_ZkDtBor/) | No | No | Dish name + hashtags | Only visible in the video. Needs a vision model, no quantities |
| 13 | Silent showpiece, not a home recipe | @amauryguichon | [blueberry cheesecake bite](https://www.instagram.com/amauryguichon/reel/DfPrpAzOmfI/) | No | No | Dish name | Nowhere. Extractor should say "no recipe" |
| 14 | Photo + full recipe in creator's own comment | @kierans__kitchen | [minted lamb hotpot](https://www.instagram.com/p/DdoQSMHtasl/) | n/a | n/a | Description + "Recipe in comments 👇" | Creator's comment, ~28 comments down |
| 15 | Photo + ingredients-only caption | @tiffycooks (old account) | [miso chili wings](https://www.instagram.com/tiffycooks/p/Bl_YaDohlUz/) | n/a | n/a | Ingredient names, no amounts or method | Caption (partial) |
| 16 | Video carousel, "recipe in comments" but not findable | @daronthechef | [honey hot salmon rings](https://www.instagram.com/p/DARemRXv6Rj/) | Not checked | Not checked | Title + "RECIPE IN COMMENTS" | Couldn't find it in the comments. Fans are asking for it too |

## Excluded

- @barefoodtim [weekly "comment PLAN"](https://www.instagram.com/barefoodtim/reel/DfHya3HsegL/): meal prep, recipes only by DM.
- @barefoodtim [bacon, sausage & egg wraps](https://www.instagram.com/barefoodtim/reel/DQeqJSNjuLy/): from his "Don't Call It Meal Prep" series.
- @emthenutritionist ["most popular recipes"](https://www.instagram.com/emthenutritionist/reel/DfNRPuJoYwr/): several recipes in one post.

## Not found yet

- Silent video with ingredients and steps as on-screen text. None of the ~20 videos sampled had this. Even Tasty narrates now.
- Photo carousel of recipe-card images.

## What each source needs

| Source | How | Login? |
|---|---|---|
| Video caption | yt-dlp (latest) | No |
| Photo caption | `instagram.com/p/<id>/embed/captioned/` | No |
| Audio | yt-dlp + Whisper | No |
| Blog link in caption | Fetch the page, read its schema.org `Recipe` data | No |
| Video frames | yt-dlp + ffmpeg + a vision model | No |
| Comments | Signed-in session | Yes |
| DM after "comment KEYWORD" | Not reachable | n/a |
