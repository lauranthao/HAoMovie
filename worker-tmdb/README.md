# HAoMovie TMDB Worker

Finds the TMDB movie or series behind a source's video, so the app's detail page can show TMDB's artwork, cast,
facts, episode stills and "you may like" (TMDB's recommendations, topped up with similar titles, in the same
TMDB request). Worker `hao-tmdb`, D1 `hao-tmdb`.

This is HAoMovie's own Worker. Its architecture follows yingxia's `Services/tmdb-match` (routes, agent rules,
caching, rate limits, D1 schema), but it runs on our own Cloudflare account, our own D1 database, our own
TMDB token and our own model keys. It never calls yingxia's Worker or uses their keys or domain.

## How it works

- `POST /v1/match` takes what the source knows about the video: `title`, and optionally `year`, `type` (`tv`|`movie`),
  `remarks`, `synopsis`, `area`, `category` (the source's category and genre tags), `episodes` (names, in order),
  `language` (`zh-CN`, `zh-TW`, `zh-HK`, `en-US`, `ja-JP`), and `source` (`{key, name}`) + `item` (the video's ID there).
  It answers with JSON lines: `{"type":"progress","step":"search","query":"…"}` while the agent works, then one
  `{"type":"result",…}` or `{"type":"error","code":"upstream|model|busy|internal",…}`.
- A result is `matched` (with `match` and `details`), `ambiguous` (with `candidates` to choose from) or `notFound`.
  Failures are errors, never `notFound`, and are not kept.
- An AI agent (`src/agent.ts`) defaults to OpenAI Responses (`AI_PROVIDER=openai`, model from `OPENAI_MODEL`,
  default `gpt-4o-mini`). Set `AI_PROVIDER=gemini` to use the retained Gemini implementation and `GEMINI_MODEL`
  (default `gemini-2.0-flash`). Both providers search TMDB with tools (`search`, `details`, `season`)
  and submit an answer. The agent may only name works the tools showed; `matched` needs confidence ≥ 0.8, else it becomes
  `ambiguous`. Budgets per run: 8 searches (pages count), 6 details, 3 seasons, 10 model turns. Before searching it
  decides whether the video can be on TMDB at all: AI-generated videos and short dramas are `notFound` (reason
  `AI-generated: …` / `Short drama: …`), kept 120 days. The app already skips videos whose source labels them so.
- A search's first 3 results come with their details, so most matches take 2–3 model calls (search, maybe one more
  check, submit). OpenAI replays tool calls and encrypted reasoning with `store: false`; prompt caching is automatic.
  When Gemini is selected, the instructions and tools every call starts with sit in a Gemini context cache
  shared by all runs: cached tokens cost a tenth. A run that finds no live cache (table `gemini_cache`) makes one for an
  hour; a changed prompt, tool or model makes a new one.
- Model calls use the retained `ModelRelay` Durable Object. OpenAI uses a US-jurisdiction subnamespace so compute
  runs in the US; a location hint alone is not a guarantee. Gemini keeps its existing objects and North American
  hint to avoid "User location is not supported" errors. The relay accepts only the two providers' API hosts.
  OpenAI requests run in an alarm event with fresh server headers, so the viewer's edge metadata is not forwarded.
  Pending requests stay in memory while their fetch handlers wait; only the alarm time is persisted. Buffered
  response bytes return to the corresponding caller, since streams cannot cross event contexts. Each upstream
  request has a 60-second timeout; a relay failure uses the transport's normal retry/error handling.
- Answers are kept in D1 by `version|title|year|type` for every viewer: matched 120 days, ambiguous 30, not found 7.
  The title is compared after NFKC, lower case and collapsed spaces only; `第四季` or a `2` still makes another title.
  Bump `VERSION` in `src/source.ts` when the prompt changes enough that old answers should go.
- `season`, `numbering` (`season`: the source counts from 1 in that season; `absolute`: across seasons) and `offset`
  (TMDB episodes before the source's first, when TMDB lists two broadcast seasons as one) let the app line its
  episodes up with TMDB's. `unmatched` holds the title's words outside the TMDB name, verbatim.
- `GET /v1/details?type=tv&id=…&season=…&language=…` gives one work's details, for a candidate the viewer picked.
- `GET /v1/catalog?feed=trending&page=1&language=zh-CN` supplies Discover's catalog rails. Feed names are
  allowlisted in `src/catalog.ts`; pages are limited to 1–500. Results retain movie/series identity, artwork,
  year, genre IDs and TMDB rating. Adult results and people are excluded from title lists.
- `GET /v1/catalog?feed=featured&language=zh-CN` supplies Discover's featured carousel (`src/featured.ts`): IMDb's
  most popular films and series (its GraphQL charts) mixed with Douban's hot films and series, Douban first for Chinese,
  each resolved to its TMDB title (`/find` by IMDb ID; a name and year search for Douban), 10 titles with artwork.
  TMDB trending fills the list when a chart fails. The built list is kept per data center for 3 hours (15 minutes when a
  chart didn't answer). The app falls back to trending when this feed fails.
- `GET /v1/catalog/collections?language=zh-CN` supplies popular people with their known works and the
  allowlisted network/studio logos. A failed individual logo lookup does not discard the other brands.
  Both catalog endpoints reuse the details rate limiter and upstream cache; neither invokes an AI model nor
  writes to the match database. TMDB credentials remain on the Worker.
- `GET /v1/catalog/search` powers the separate Discover search. `mode=search&q=…&kind=movie|tv|person`
  returns paged title cards or people; `mode=recommend&feed=day|week|popular` supplies the initial groups.
  `mode=discover` supports bounded genre, year, rating, vote-count, runtime, language, region, network/studio,
  and keyword filters. `mode=keywords&q=…` resolves keyword IDs; `mode=person&id=…` returns a deduplicated
  filmography. The handler validates all parameters before accessing TMDB, has its own 120/minute limiter,
  and never accesses source-video search, AI models or D1. Search history stays on the device.
- Reverse lookup: matched answers and viewers' picks (`POST /v1/link`) are kept in `links`, one row per source video.
  `GET /v1/search?q=…` searches TMDB and says how many source videos each result has; `GET /v1/sources?type=&id=`
  lists them. An agent's answer never replaces a viewer's pick.
- TMDB answers are cached per data center for a day (Cache API). 429s wait for Retry-After and try again. Model 429s
  wait when the wait is short (per-minute limits); exhausted quota and long waits fail at once.
- Limits: 20 runs a minute per IP (only cache misses), `DAILY_RUNS` agent runs a day in all.

## What this Worker does NOT do (yet)

- No airing calendar (`/v1/calendar` in yingxia's Worker): not part of this leg. Add it later if the app needs one.
- No custom domain yet: it deploys to `*.workers.dev` until a domain is chosen. The app client must take the
  base URL from config, not hardcode it.

## Deploy

Run from this folder (`worker-tmdb/`). The deployer needs a Cloudflare account with Workers + D1.

```sh
npm install
npx wrangler d1 create hao-tmdb
# Put the returned database_id into wrangler.jsonc (replacing REPLACE_WITH_CREATED_DATABASE_ID).
npx wrangler d1 execute hao-tmdb --remote --file schema.sql
npx wrangler secret put TMDB_TOKEN   # TMDB's v4 read access token
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put GEMINI_API_KEY # only needed if AI_PROVIDER=gemini
npx wrangler deploy
```

Secrets belong in Worker secrets. For local development use an ignored `.dev.vars` file; never put keys in
`wrangler.jsonc`, app sources or the website. Missing selected-provider credentials fail explicitly; there is no
automatic fallback to another provider. Existing cached matches remain valid and are reused until expiry.

An existing database gets new columns and tables from `migrations/` (`npx wrangler d1 execute hao-tmdb --remote --file migrations/…`).

## Secrets (values are NOT in this repo — the deployer injects them)

| Secret | What it is | Required |
|---|---|---|
| `TMDB_TOKEN` | TMDB v4 read access token (Bearer token for api.themoviedb.org/3) | Always |
| `OPENAI_API_KEY` | OpenAI API key, for the default provider | When `AI_PROVIDER=openai` (default) |
| `GEMINI_API_KEY` | Gemini API key | Only when `AI_PROVIDER=gemini` |

Vars (plain, in `wrangler.jsonc`): `AI_PROVIDER` (`openai`|`gemini`, default `openai`), `OPENAI_MODEL`
(default `gpt-4o-mini`), `GEMINI_MODEL` (default `gemini-2.0-flash`), `DAILY_RUNS` (default `2000`).

## Check answers

```sh
npx wrangler d1 execute hao-tmdb --remote --command "SELECT title, status, media_type, tmdb_id, season, confidence, reason FROM matches ORDER BY created DESC LIMIT 50"
```

Fix a wrong one by deleting its row; the next viewer asks again.

## Local checks

```sh
npm install
npm run check   # tsc --noEmit
```

This product uses the TMDB API but is not endorsed or certified by TMDB.

### People and related browsing

`GET /v1/catalog/search?mode=profile&id=<person-id>&language=<language>` returns a localized person profile and combined movie/TV credits. Each work retains its full date, roles and contribution departments; duplicate cast/crew appearances merge by typed media identity. Undated works follow dated works.

Title details retain optional person IDs, `genreItems` (ID and localized name), and studio IDs with `network`/`company` kind. Related pages query the existing discover mode with `genres`, `networks` or `companies`, preserving media type, sorting and pagination. Platform IDs accept bounded positive integers instead of only the home page's preset brands. Profile requests share the catalog search limiter.

## File map (yingxia source → this Worker)

| This file | Follows yingxia `Services/tmdb-match/` |
|---|---|
| `src/index.ts` | `src/index.ts` — routes, match flow, D1 cache, relay, cron cleanup (no calendar, no cover proxy) |
| `src/agent.ts` | `src/agent.ts` — prompt rules, tools, budgets, verdict |
| `src/details.ts` | `src/details.ts` — details, cast/crew, recommendations, `facts`, `brief` |
| `src/tmdb.ts` | `src/tmdb.ts` — TMDB v3 client, day cache, 429 retry |
| `src/catalog.ts` | `src/catalog.ts` — catalog feeds, collections |
| `src/catalog-search.ts` | `src/catalog-search.ts` — Discover search/discover/recommend/person/keywords |
| `src/catalog-person.ts` | `src/catalog-person.ts` — person profile + filmography |
| `src/featured.ts` | `src/featured.ts` — IMDb + Douban featured carousel |
| `src/openai.ts` | `src/openai.ts` — OpenAI Responses transport |
| `src/provider.ts` | `src/provider.ts` — provider/model selection from env |
| `src/model.ts` | `src/model.ts` — ModelError, ToolCall, ToolResult |
| `src/source.ts` | `src/source.ts` — request parsing, cache key (`VERSION = "1"`) |
| `schema.sql` | `schema.sql` — matches, usage, links, gemini_cache (no calendars table) |
| `migrations/0002–0004` | `migrations/0002–0004` — links, episode_offset, gemini_cache |
| `wrangler.jsonc` | `wrangler.jsonc` — own Worker name `hao-tmdb`, own D1 `hao-tmdb`, own rate-limit namespaces |
