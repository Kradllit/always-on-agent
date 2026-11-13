# Wander: a city companion that learns your taste as you walk

Clickable prototype of an always-on exploration agent. You give it a few starting interests,
then it watches where you go, taps you on the shoulder when you pass something you'd like,
learns from what you stop for, skip or linger at, and keeps rewriting your itinerary.

Open `index.html` in a browser (or serve the folder, e.g. `python3 -m http.server 8790`).
No build step. The demo walks a simulated route through San Francisco
(Ferry Building, Jackson Square, Chinatown, North Beach, Telegraph Hill, Exploratorium).

## What's on screen

- **Phone (left):** onboarding, live map with callout cards, the Plan tab (itinerary that
  replans itself) and the You tab (what Wander has learned about you).
- **Agent brain (right):** context window, the taste model updating in real time, the tap
  threshold, places it chose to stay quiet about, written reflections, and a tool-call trace.
- **Demo controls:** Walk / pause, speed, Linger (simulates stopping for 10 minutes), restart.

## How the learning loop works

`Sense → Score → Nudge → Learn → Replan`

- **Score:** each place has weighted tags. Match = your taste weights x the place's tags,
  plus time-of-day fit (lunch, dinner, bars after 5), short-term intent ("I'm hungry") and
  satiety (food fades for ~2 hours after you eat).
- **Nudge:** only if the match clears the tap threshold θ. Everything else is logged as
  "stayed quiet about".
- **Learn:** explicit signals (going in, saving, "not my thing", "not right now", "been there")
  and implicit ones (lingering, ignoring a callout) update the taste model. Negative signals are
  credited mostly to tags you haven't vouched for, so skipping a glass tower lowers "modern
  towers" rather than "architecture". θ adapts to how often you say yes.
- **Reflect:** Wander writes notes to itself ("New interest: Italian", "old buildings over glass
  towers"). These and the taste model persist in localStorage, so a second trip starts from
  what it already knows.
- **Replan:** greedy itinerary over open places, weighing match, walking time, opening hours and
  meal spacing, rebuilt after every signal with a note on what changed and why.

## Claude

Works fully offline with templates. Add an Anthropic API key under **⚙︎ Claude** and Claude
writes the callouts, answers "Ask Wander", and produces reflections (defaults to Claude Opus 5.5
at low effort; Haiku 5.5 is selectable for lower latency). The key stays in the browser; a real
deployment should proxy calls through a backend.

## Next steps

- Live mode: device GPS plus OpenStreetMap / Places data so it works in any city.
- Move the agent loop server-side (Claude tool use: `nearby_places`, `score`, `notify`,
  `update_taste`, `replan`) with the profile as durable memory.
- Push notifications or the Jensen badge as the "tap on the shoulder".
