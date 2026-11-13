# Plan: real nearby places for Jensen (`GET /nearby`)

**Status (2026-11-13): plan only. No code has been written yet.** If you are an agent working on
another part of this repo, read this to see what is coming and how it affects your part. Then
change your work to fit, or flag a conflict before it gets built.

## In one paragraph

Jensen's brain (`jensen/`) can judge a place and explain why it fits someone, but nothing in the
repo finds real places with any story behind them yet. We will add one endpoint to the brain
server, `GET /nearby?lat=..&lon=..`. It looks up what is around a point using two free sources
that need no key: **Wikipedia**, for landmarks, buildings of note and history, and
**OpenStreetMap**, for restaurants, cafes, bars, museums and historic sites. It returns places
in the same shape `POST /recommend` already accepts. Every client (the iPhone app, Wander, the
prototype) can then get real places, and each place comes with a short "known about it" summary
the model can use.

## Where things stand today

| Part | Where it gets places now | What's missing |
|---|---|---|
| `jensen/` (brain server, Bun + Claude) | Nowhere. `POST /recommend` judges whatever place the caller sends. | A way to find places. |
| `ios/` (on the `ios-app` branch, not on `main` yet) | Apple MapKit (`PlaceFinder.swift`), no key, matched to interests by a small table. | No history or description, only a name and a category. Doesn't call the brain yet. |
| `wander/` | A hard-coded San Francisco route and place list. | Live places in any city. Its README lists "OpenStreetMap / Places data" as the next step. |
| `prototype/` | A hard-coded `PLACES` list with local images. | Nothing urgent; it's a demo. |
| `badge/` | Receives text over Bluetooth from the phone. | Nothing; not affected. |

## The endpoint (proposed contract)

```
GET /nearby?lat=37.7955&lon=-122.3937&radius_m=400&limit=40
```

- `lat`, `lon`: required. `radius_m`: default 400, clamped to 50–2000. `limit`: default 40.
- Response:

```json
{
  "places": [
    {
      "name": "Ferry Building",
      "category": "landmark",
      "address": "1 Ferry Building",
      "lat": 37.7955, "lon": -122.3937, "distance_m": 12,
      "summary": "Terminal for ferries ... (first sentences of the Wikipedia article; plus hours, cuisine, year built or architect when OpenStreetMap has them)",
      "url": "https://en.wikipedia.org/wiki/Ferry_Building",
      "source": "wikipedia+osm"
    }
  ],
  "sources": { "wikipedia": "ok", "osm": "ok" },
  "ms": 640
}
```

The values above show the shape only; they are not a real response. Each place matches the
existing `Place` type in `jensen/brain.ts`, plus a `source` field (`wikipedia`, `osm` or
`wikipedia+osm`), which clients need in order to credit their sources (see "Licences" below).
Results are sorted nearest first.

### How it works

1. **Wikipedia, search by location:** articles near the point, with their coordinates, short
   description and first two sentences. This is the history and landmark layer.
2. **OpenStreetMap, through the Overpass API:** named places tagged as restaurants, cafes, bars,
   pubs, ice cream or fast food; museums, attractions, viewpoints, galleries and artworks; and
   anything tagged `historic`. Useful extra tags go into `summary`: cuisine, opening hours, year
   built, architect, heritage listing.
3. **Merge:** when an OpenStreetMap place links to the same Wikipedia article, or has the same
   name within about 60 m, keep one entry. It gets OpenStreetMap's category, address and hours,
   and Wikipedia's summary.
4. **Cache:** about 10 minutes per roughly 100 m square, in memory. The iPhone app looks every
   15 seconds, and the public Overpass server has usage limits, so a phone standing still must
   cost one lookup, not hundreds. Distances are still worked out from the exact point asked about.
5. **One source down is fine:** if either source fails or times out (after about 8 s), return
   the other source's places and report the failure in `sources`. Overpass often answers busy
   (429/504).
6. Send a generic client name in the User-Agent header (`jensen-hackathon/0.1`), with no
   personal contact details.

**Not in this first version:** Wikidata facts (architect, year built, heritage status as
structured data), Google Places for live hours and ratings, languages other than English, and a
cache that survives restarts. These are the next steps if the first version proves useful.

## What each part should do with it

**The rule for everyone: filter in code before you call the model.** `/nearby` can return 40
places, and calling `/recommend` on each one means 40 model calls. Pick candidates cheaply
first: places not shown yet, a category that matches an interest, nearest first. Then send only
the top one to three to `/recommend`. Its "no" answers are still useful; they keep the badge quiet.

- **`ios/` (iPhone app):** this has the most to gain. The app can't ship a Claude key, so it
  has to talk to the brain server anyway.
  - Keep MapKit as the main way to find places. It covers more and gives the street-level photo.
  - Call `/nearby` at the same position, and attach the `summary` and `url` of any match (same
    name, ignoring case, within about 75 m) to the MapKit place.
  - Add Wikipedia-only results (`source` = `wikipedia`) as extra "landmark" candidates for
    history or architecture interests. MapKit misses many of these.
  - Send the chosen place to `POST /recommend`, and show its `headline` and `why` in the chat
    and on the badge, not just "name, distance".
- **`wander/`:** add a live mode next to the existing offline demo route; keep the demo route as
  the default. In live mode, fetch `/nearby` for the current position and map `category` and
  OpenStreetMap tags onto Wander's own tags so its scoring keeps working. The server already
  allows calls from any browser page (CORS).
- **`prototype/`:** optional and lowest priority. It can stay on its hard-coded list.
- **`badge/`:** no change. It still gets text from the phone, and `/recommend` already keeps
  `headline` to at most 4 words.

## Licences and credit (check current terms before shipping anything)

- **Wikipedia** text is CC BY-SA. Wherever a summary is shown to the person, show "From
  Wikipedia" with a link to the article. That's why the response includes `url` and `source`.
- **OpenStreetMap** data is ODbL. Show "© OpenStreetMap contributors" wherever OpenStreetMap
  places are shown. The public Overpass server is for light, fair use, which is another reason
  for the cache.
- For reference, here are other sources we looked at and why they're not in this version:

| Source | Why not now |
|---|---|
| Google Places | Best coverage, but paid, and its terms limit storing results. Good later for live opening hours, called only when Jensen is about to tap someone. |
| Overture Maps places, Foursquare's open places dataset | Free, with permissive licences and more coverage than OpenStreetMap in places. They need a download per city; worth it if OpenStreetMap coverage is thin. |
| Yelp | Paid, with strict storage and display terms. |
| OpenTable, Resy | No open public API. The brain's booking tool already uses links instead. |
| National Register of Historic Places, city landmark lists (for example DataSF) | Public data and good for history, but specific to the US or to one city. Wikipedia covers most of the same sites. |

## How we'll know it works

- Type-check passes (`bun run check` in `jensen/`).
- The merge and de-duplication logic is tested against saved sample responses from both sources,
  with no network calls.
- Live check at the Ferry Building (37.7955, -122.3937, the spot `ios/README.md` already uses for
  the simulator): both sources report `ok`, a well-known place nearby comes back with a Wikipedia
  summary, and at least a few restaurants or cafes come back from OpenStreetMap.
- With one source made unreachable, the endpoint still answers with the other's places and
  reports the error in `sources`.
- Two calls a few seconds apart at the same spot make only one round of outside lookups.

## Files the build will touch

- `jensen/nearby.ts` (new): the two lookups, the merge and the cache.
- `jensen/server.ts`: one new route, plus a line in the endpoint list at the top of the file.
- This plan: updated to describe what was actually built.

Nothing else on `main` changes. The iPhone app and Wander pick it up in their own workstreams,
as described above.
