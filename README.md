EcoAI
EcoAI is a custom language model designed to tackle a problem we don't talk about enough: the massive energy and environmental cost of running modern AI.

Instead of hiding resource usage behind the scenes, EcoAI actively tracks, calculates, and displays its own energy and compute consumption in real-time as you chat with it. By giving you immediate feedback on the computational weight of your prompts, it encourages smarter, more efficient AI usage without sacrificing quality.

## Friends and energy leaderboard (Work in progress)

Open **Friends & leaderboard** in the chat sidebar to copy your invite code or send a friend request using theirs. Friend requests must be accepted before either person’s weekly energy total appears in the comparison. Accepted friends are ranked by weekly electricity use, with the lowest total first. EcoAI shares weekly watt-hours and token totals, not chat content.

Friend profiles, requests, and weekly totals are stored in Cloudflare D1 by the Worker. Before deploying the Worker, create and bind the database:

```sh
cd backend
npx wrangler d1 create ecoai-friends
```

Copy the returned database ID into the `DB` binding’s `database_id` field in `wrangler.jsonc`, replacing its all-zero placeholder. Then apply the schema and deploy:

```sh
npx wrangler d1 migrations apply ecoai-friends --remote
npx wrangler deploy
```

For local Worker development, apply the migration locally with `npx wrangler d1 migrations apply ecoai-friends --local` before running `npx wrangler dev`.
