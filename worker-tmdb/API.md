# API 契约 — HAoMovie TMDB Worker

供下一腿 app 端接 client 用。Base URL 由部署时确定（`*.workers.dev`，或之后绑定的自定义域名），app 端从配置读，不要 hardcode。
语言参数 `language` 统一取值 `zh-CN | zh-TW | zh-HK | en-US | ja-JP`，缺省 `zh-CN`。非法值返回 400。
所有 GET（除 `/v1/search`、`/v1/sources` 外）都有 `Cache-Control`，见各条。

通用类型：

```jsonc
// 一张作品卡片（catalog / search / recommendations / candidates 共用）
{
  "mediaType": "tv" | "movie",
  "id": 123,                 // TMDB id（数字）
  "name": "…",               // 本地化名
  "originalName": "…",       // 原名
  "year": 2024 | null,
  "poster": "https://images.tmdb.org/t/p/w500/….jpg" | null,
  "backdrop": "https://images.tmdb.org/t/p/w1280/….jpg" | null, // 仅 catalog/search 的部分返回有
  "overview": "…",           // 可能为空字符串
  "rating": 8.1 | null,      // TMDB vote_average，无有效票数时 null
  "genreIDs": [18, 80]       // 仅 catalog 返回有
}
```

---

## 1. `POST /v1/match` — 标题匹配（核心）

请求（JSON，≤ 64 KB）：

```jsonc
{
  "title": "庆余年 第二季",   // 必填，≤100 字符
  "year": "2024",            // 可选，4 位年份
  "type": "tv" | "movie",    // 可选，源站能确定时传
  "remarks": "更新至第36集",  // 可选，≤80 字符
  "synopsis": "…",           // 可选，≤1000 字符
  "area": "大陆",             // 可选，≤40 字符
  "category": "古装 / 权谋",  // 可选，源站分类/类型标签，≤80 字符
  "episodes": ["第1集", "第2集"], // 可选，剧集名按顺序，最多 2000 条、每条 ≤60 字符
  "language": "zh-CN",       // 可选，缺省 zh-CN
  "source": { "key": "sub-xxx", "name": "某源" }, // 可选；传了才写 links 反查
  "item": "vod-123"          // 可选；该视频在源站的 ID，与 source 一起用
}
```

响应：`application/x-ndjson` 流，每行一个 JSON。先是 0 条或多条进度行，最后是一行结果或错误行。
客户端必须按行读，读到 `type: "result"` 或 `type: "error"` 为止。

进度行：

```jsonc
{ "type": "progress", "step": "thinking", "turn": 0 }
{ "type": "progress", "step": "search", "query": "庆余年" }
{ "type": "progress", "step": "details", "name": "庆余年", "year": 2019 }
{ "type": "progress", "step": "season", "season": 2 }
{ "type": "progress", "step": "waiting" }   // 同标题已有一次 agent 在跑，等它
{ "type": "progress", "step": "loading" }   // 匹配成功，正在取详情
{ "type": "progress", "step": "done" }      // 未匹配，结束
```

结果行（`matched`）：

```jsonc
{
  "type": "result",
  "status": "matched",
  "match": {
    "mediaType": "tv",
    "id": 99999,
    "season": 2,             // 仅 tv 有；movie 为 null
    "numbering": "season",   // "season" | "absolute"
    "offset": 0,             // TMDB 季内源站第一集之前的集数（合季时 >0）
    "confidence": 0.92,      // ≥ 0.8 才是 matched
    "unmatched": "第二季"    // 源标题里不在 TMDB 名里的词，原样；无则 ""
  },
  "season": 2,
  "numbering": "season",
  "unmatched": "第二季",
  "candidates": [ /* 作品卡片（不含 backdrop/overview 之外字段），最多 4 个备选 */ ],
  "details": { /* 见 §2 Details 对象；matched 时才有 */ },
  "cached": false            // true 表示命中 D1 缓存，未跑 agent
}
```

结果行（`ambiguous` / `notFound`）：`match: null`，`details: null`；`ambiguous` 时 `candidates` 为按可信度排好的候选（最多 5 个），app 展示给用户选，选完调 `POST /v1/link`；`notFound` 时 `candidates: []`。

错误行：

```jsonc
{ "type": "error", "code": "upstream" | "model" | "busy" | "internal", "message": "…" }
```

- `busy`：每 IP 每分钟 20 次（仅缓存未命中时计）或当日 `DAILY_RUNS`（默认 2000）已满，稍后再试。
- `upstream`：TMDB 不可用；`model`：模型调用失败；`internal`：其他内部错。
- 失败不是答案：不缓存、不返回 `notFound`，app 应显示“查找失败”而不是“找不到”。

HTTP 状态：请求体非法（无 title、>64 KB）返回 400/413（非 NDJSON）；agent 正常跑完一律 200 + NDJSON 流。
缓存：同一 `version|title|year|type` 的答案 D1 共享：matched 120 天、ambiguous 30 天、notFound 7 天（AI 生成/短剧的 notFound 按 120 天）。

---

## 2. `GET /v1/details?type=tv&id=123&season=2&language=zh-CN` — 单作品详情

- 参数：`type`（`tv`|`movie`，必填）、`id`（正整数，必填）、`season`（0–999 的整数，仅 tv 有效，可选）、`language`（可选）。
- 200 + `Details` JSON（`Cache-Control: public, max-age=3600`）；TMDB 无此作品返回 404；上游失败 502。
- 限流：每 IP 每分钟 60 次，超了 429。

```jsonc
{
  "mediaType": "tv",
  "id": 123,
  "name": "…",
  "originalName": "…",
  "tagline": "…",            // 可能为空字符串
  "overview": "…",
  "year": 2024 | null,
  "date": "2024-05-16" | null, // 首播/上映日期
  "genres": ["剧情", "古装"],   // 本地化名
  "genreItems": [{ "id": 18, "name": "剧情" }], // 供相关页按类型筛选
  "runtime": 45 | null,      // tv 为单集时长，movie 为片长（分钟）
  "rating": 8.1 | null,      // TMDB vote_average，无有效票数时 null
  "voteCount": 1234,
  "countries": ["CN"],       // tv: origin_country；movie: production_countries
  "status": "Returning Series" | null,
  "poster": "https://images.tmdb.org/t/p/w500/….jpg" | null,
  "backdrop": "https://images.tmdb.org/t/p/w1280/….jpg" | null,
  "logo": "https://images.tmdb.org/t/p/w500/….png" | null,       // PNG 词标
  "heroPoster": "https://images.tmdb.org/t/p/w780/….jpg" | null, // 无字竖版海报
  "trailer": { "site": "YouTube", "key": "…" } | { "site": "IMDb", "key": "tt…" } | null,
  "stills": ["https://images.tmdb.org/t/p/w780/….jpg"], // 最多 8 张剧照
  "studios": [{ "id": 1 | null, "kind": "network" | "company", "name": "…", "logo": "…w300…" | null }], // 最多 8 个
  "cast": [{ "id": 11 | null, "name": "…", "role": "…角色名…" | null, "profile": "…w185…" | null }], // 最多 16 人
  "crew": [{ "id": 22 | null, "name": "…", "role": "Creator" | "Director", "profile": "…" | null }], // tv: 主创最多 4 人；movie: 导演最多 3 人
  "networks": ["…"],         // 最多 3 个出品方/播出方名
  "seasons": [{ "number": 1, "name": "第 1 季", "episodeCount": 36, "year": 2019 | null, "poster": "…w342…" | null }],
  "season": {                // 传了 season 且该季存在时才有，否则 null
    "number": 2, "name": "第 2 季", "overview": "…",
    "poster": "…w342…" | null, "year": 2024 | null,
    "episodes": [{ "number": 1, "name": "…", "overview": "…", "still": "…w300…" | null, "airDate": "2024-05-16" | null, "runtime": 45 | null, "rating": 7.9 | null }]
  },
  "recommendations": [ /* 作品卡片，最多 12 个：TMDB recommendations 优先，similar 补齐；都有 poster */ ],
  "link": "https://www.themoviedb.org/tv/123"
}
```

---

## 3. `GET /v1/catalog?feed=trending&page=1&language=zh-CN` — 发现页榜单

- `feed`（必填其一，非法值 400）：`trending`、`movies`、`television`、`onTheAir`、`nowPlaying`、`upcoming`、
  `topMovies`、`topTelevision`、`animation`、`chinese`、`korean`、`variety`、`family`、`kids`、`netflix`、`disney`、
  `appleTV`、`hbo`、`warner`、`universal`、`paramount`、`sony`、`featured`。
- `page`：1–500，缺省 1。`language` 缺省 `zh-CN`。
- 200 + `{ "items": [作品卡片…], "page": 1, "totalPages": 25 }`（`Cache-Control: public, max-age=3600`）。
- `featured`：IMDb 热门 + 豆瓣热门混合的 10 条精选（都有 poster 和 backdrop），不足 10 条时 TMDB trending 补齐；
  榜单失败时 app 回落到 `feed=trending`。限流：每 IP 每分钟 60 次（走 DETAILS_LIMITER），超了 429。

---

## 4. `GET /v1/catalog/collections?language=zh-CN` — 热门人物 + 品牌

- 200 + `{ "people": [{ "id": 1, "name": "…", "profile": "…w185…", "works": [作品卡片…] }], "networks": [{ "feed": "netflix", "name": "Netflix", "logo": "…w500…" | null }], "companies": [{ "feed": "warner", "name": "Warner Bros.", "logo": "…" | null }] }`（最多 16 人，只保留有代表作的人）。
- `networks` 的 `feed` 可直接当 `GET /v1/catalog?feed=<feed>` 用；`companies` 同理。
- 限流：每 IP 每分钟 60 次，超了 429。

---

## 5. `GET /v1/catalog/search` — 发现页搜索/筛选/人物

共用参数：`language`（缺省 `zh-CN`）、`page`（1–500，缺省 1）、`kind`（`movie`|`tv`|`person`，缺省 `movie`）。
参数非法一律 400；限流：每 IP 每分钟 120 次，超了 429。响应 `Cache-Control: private, max-age=300`。

| mode | 参数 | 返回 |
|---|---|---|
| `search`（缺省） | `q`（必填，≤100 字符） | `{ items, people, keywords: [], page, totalPages }`：`kind=movie\|tv` 时 `items` 为作品卡片；`kind=person` 时 `people` 为人物卡片 |
| `recommend` | `feed=day\|week\|popular`（缺省 `week`） | 同上，初始推荐分组（trending/popular） |
| `discover` | 见下 | 同上，按筛选条件查 |
| `keywords` | `q`（必填） | `{ items: [], people: [], keywords: [{id, name}]（≤20）, page: 1, totalPages: 1 }` |
| `person` | `id`（必填，正整数） | `{ items: [作品卡片…]（≤200，按热度排）, people: [], keywords: [], page: 1, totalPages: 1 }`（去重后的合集作品） |
| `profile` | `id`（必填） | 见 §6 人物档案 |

`discover` 筛选参数（全部可选；`kind=person` 时不可用）：
`genres`（类型 ID，逗号分隔，最多 8 个；movie/tv 各有允许集合）、`originalLanguage`（`zh|en|ja|ko|fr|de|es|it|hi|th`）、
`region`（`CN|HK|TW|US|GB|JP|KR|FR|DE|IN|TH`）、`rating`（0–10）、`votes`（0–1000000）、
`minRuntime`/`maxRuntime`（0–600 分钟）、`networks`（仅 tv，平台 ID）、`companies`（仅 movie，制片厂 ID）、
`keywords`（关键词 ID）、`from`/`to`（年份 1870–2100）、`sort`（`popularity.desc|popularity.asc|vote_average.desc|
vote_average.asc|date.desc|date.asc|revenue.desc|vote_count.desc`，缺省 `popularity.desc`；`revenue.desc` 仅 movie）。
带 `q` 时先按标题搜再在结果里套筛选。

人物卡片：`{ "id": 1, "name": "…", "profile": "…w185…" | null, "department": "Acting" | null, "works": [作品卡片…] }`。

---

## 6. `GET /v1/catalog/search?mode=profile&id=123&language=zh-CN` — 人物档案

- 200 + `{ "id": 123, "name": "…", "profile": "…w500…" | null, "biography": "…", "birthday": "1980-01-01" | null, "birthplace": "…" , "department": "Acting", "instagram": "xxx" | null, "works": [{ "item": 作品卡片, "date": "2024-05-16" | null, "roles": ["…"], "departments": ["Acting", "Directing"] }] }`。
- `works` 按日期倒序排，无日期的在后；同一作品多身份合并为一条。
- 人物不存在/成人内容时 400（`Person unavailable`）或上游错 502。

---

## 7. `GET /v1/search?q=…&language=zh-CN` — 全局搜 TMDB（带源站计数）

- `q`（必填，≤100 字符）。200 + 作品卡片数组，每项多一个 `sources`（数字：有多少源站视频链接到该作品）与 `overview`（≤300 字符）、`backdrop`（w780）。
- 限流：每 IP 每分钟 60 次，超了 429；上游失败 502。

## 8. `GET /v1/sources?type=tv&id=123` — 某作品链接的源站视频

- 200 + 数组（最近 seen 在前，最多 200 条）：`[{ "source": "sub-xxx", "sourceName": "某源", "item": "vod-123", "title": "…", "year": "2024" | null, "season": 2 | null, "seen": 1710000000 }]`。
- 限流：每 IP 每分钟 60 次，超了 429。

## 9. `POST /v1/link` — 用户手动选了作品（“不是这个？”）

请求：

```jsonc
{
  "request": { /* 与 §1 相同的 match 请求体：title / source / item 等 */ },
  "mediaType": "tv" | "movie",
  "id": 123,          // TMDB id
  "season": 2         // 可选，仅 tv
}
```

- 成功 204（无 body）；限流每 IP 每分钟 60 次，超了 429；参数非法 400。
- 写入 `links`：之后所有用户在该源站视频上都会看到这次人工选择；agent 的答案永远不覆盖人工选择。

---

## 备注

- 本 Worker 没有 `/v1/calendar`（映匣有，本腿不做）；app 不要调。
- 所有图片 URL 均为 TMDB CDN 直链，app 直接加载即可。
- `rating` 为 TMDB 评分（`vote_average`），与豆瓣评分不是一回事，UI 上不要标成豆瓣分。
- 详情页“你可能喜欢”直接用 `details.recommendations`；相关页按类型/平台筛选直接调 `mode=discover` + `genres`/`networks`/`companies`。
