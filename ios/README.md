# Jensen, the phone app

A SwiftUI app for iPhone (iOS 26). You pick what you're into, put the phone away and walk.
Jensen's brain (`jensen/`, running Claude) watches where you are and picks places that fit
you. Each pick pops up on the phone and shows on the badge (Bluetooth): the card with its
name and why it fits you, its photo, and the walking time.

## What it does

1. **Onboarding** (one screen, from Wander, `wander/index.html`): interest chips (two or
   more), your pace, the time you have today and how often Jensen should tap you, then
   Start. It remembers you on the next launch and greets you back. Interests come only
   from these chips; "Edit starting picks" in the You screen brings the screen back.
2. **Pairing with the badge**: tap the line under the title. The app lists the badges nearby
   that run the hackathon firmware (service `ba5eca3b-0001`), nearest first. Pair with one
   and it is remembered and reconnects by itself, in the background too. The header says
   "Badge connected" with its battery level.
3. **Picks from the brain**: every 3 seconds the app asks `GET /badge/next` what the brain's
   always-on watcher chose. Each pick:
   - pops up over the chat like the badge in `prototype/index.html`: the round photo
     springs in with the headline and walking minutes, a white ring counts down 8 seconds,
     and a tap shows why Jensen picked it;
   - leaves a card in the chat with Going in, Not my thing, Not now and Been there, each
     sent to the brain (`POST /feedback`) as Wander's learning signals;
   - goes to the badge as one line, `headline|why||4 min walk`, then its photo;
   - shows as a notification with the photo, sent at the same moment as the badge line.
4. **Talking to Jensen**: anything typed in the chat goes to Claude through `POST /ask`.
   Hold the mic to say it instead: Apple's speech recognition turns it into text (on the
   iPhone where it can). Jensen shows that it is typing, then the reply appears in the
   chat with any booking or ticket links. The reply is also spoken aloud and shown on the
   badge. "Recommend a place near me" works: the brain looks around where you are.
5. **You screen** (menu, "You: what Jensen learned"): what you told it, what you went into
   or passed on, what you saved for later, and notes drawn only from what you did. It also
   has Edit starting picks and Forget everything.

## Demo walk

"Demo walk" (top left) walks for you: Apple Maps' walking route from the Ferry Building to
Coit Tower at walking pace, with a 1x / 5x / 20x switch and a map. Each step is reported to
the brain like a real GPS position, so the brain picks places along the way. **Demo at 5x**:
at 20x the walker outruns the brain's picks. The interview has to be done first; the location
question does not.

Launching with `-demoWalk 5` sets off at once at that speed. On a phone:
`xcrun devicectl device process launch --console --device <udid> com.kradllit.jensen -- -demoWalk 5`
(`--console` shows the app's `brain:` and `badge:` log lines).

## The brain

The app talks to the team's hosted brain, set as the default in `BrainLink.swift`
(`BrainLink.hosted`). Menu, "Jensen server", changes the address, for example to
`http://192.168.1.20:8787` for `bun server.ts` on a laptop on the same Wi-Fi. What it uses:

| Call | When |
|---|---|
| `POST /profile` | after onboarding and on every launch: interests, `prefs` {pace, time_min, chat} |
| `POST /location` | every position, real or demo |
| `GET /badge/next?profile_id=..&consumer=phone` | every 3 s: the watcher's next pick, with `headline`, `why` and `place.image` |
| `POST /feedback` | Going in, Not my thing, Not now, Been there on a card |
| `POST /ask` | every typed or spoken message |

When the brain answers 400 for an unknown `profile_id` (it restarted), the app posts the
profile again with the saved answers and repeats the call, without asking.

`GET /nearby` and `POST /recommend` are wired too (the app's own picks from Apple Maps, ranked
by the brain), but switched off with `Jensen.ownPicks = false`. For the demo, the brain's
watcher does the choosing.

## The badge link

`BadgeLink.swift` is one end; `badge/src/ble.rs` is the other (firmware in
[Kradllit/basecamp-badge](https://github.com/Kradllit/basecamp-badge)).

- Service `ba5eca3b-0001-4b1d-9e5a-0d1e2f3a4b5c`: status `0002` (read, notify; JSON
  with battery), command `0003` (a line of text), picture `0004`.
- A pick is one line, `headline|why||note`. The third part, a picture address, stays empty
  because the photo comes over Bluetooth. An answer to a question is a plain line, which the
  badge shows as a card of text. Latin-1 letters only.
- The photo is a square 234 x 234 JPEG, sent after the badge acknowledges the line. The
  first piece is `JPG1` plus the length (4 bytes, low byte first). Then come the bytes,
  at most 253 per piece. **Every piece is written with response and the next waits for the
  acknowledgement**: written without response, only the first piece arrived. A 15 KB photo
  takes about 4 s.
- The scan has no service filter. The advert has no room for the name next to the 128-bit
  UUID, so badges are matched by the service. iOS may show a badge under an old cached
  name; this board showed as "Concrete Badge". The app labels badges by their service.
- The status line at the foot of the Badge sheet (tap the line under the title) shows each step: Bluetooth permission and power,
  scanning, the badges seen with their signal, connect requested, connected, service found,
  ready, line acknowledged, picture sent, and the last error.
- **If the badge never connects** ("timed out" over and over), the iPhone may still hold a
  pairing for the same board from other firmware. Go to Settings, Bluetooth, tap (i) next to
  the badge (here "Concrete Badge") and choose Forget This Device. The Badge sheet's status line
  suggests this too.

## Run it

Open `Jensen.xcodeproj` in Xcode 27, pick a simulator or your iPhone, and press Run. On a
phone, choose your own team under Signing & Capabilities first; no team is saved in the
project. From the command line:

```sh
xcodebuild -project Jensen.xcodeproj -scheme Jensen -destination 'id=<iphone udid>' \
  -derivedDataPath build DEVELOPMENT_TEAM=<your team id> -allowProvisioningUpdates build
xcrun devicectl device install app --device <udid> build/Build/Products/Debug-iphoneos/Jensen.app
xcrun devicectl device process launch --device <udid> com.kradllit.jensen
```

The simulator has no Bluetooth, so the badge line says "Bluetooth off" there; everything
else works:

```sh
xcodebuild -project Jensen.xcodeproj -scheme Jensen \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
xcrun simctl boot "iPhone 18 Pro"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Jensen.app
xcrun simctl launch booted com.kradllit.jensen -demoWalk 5
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing a file, run `xcodegen` in this folder and commit the result.

## The code

| File | What |
|---|---|
| `Jensen/Jensen.swift` | Jensen: onboarding answers, polling the brain's picks, questions, learning signals |
| `Jensen/OnboardingView.swift` | Wander's one-screen onboarding |
| `Jensen/ChatView.swift` | The chat screen, header, composer with hold-to-talk |
| `Jensen/PopUp.swift` | The pick popping up as on the badge, and its card in the chat with the feedback buttons |
| `Jensen/YouView.swift` | What Jensen has learned about you |
| `Jensen/BrainLink.swift` | The link to the brain (`jensen/server.ts`) |
| `Jensen/BadgeLink.swift` | The Bluetooth link to the badge: pairing, reconnecting, lines and photos |
| `Jensen/BadgeSheet.swift` | Pairing: badges nearby, the paired one, wave, forget, and the Bluetooth status line |
| `Jensen/Listener.swift` | Press-to-talk (speech recognition) and speaking replies |
| `Jensen/PlaceFinder.swift` | Where the phone is, Apple Maps places, a place's picture |
| `Jensen/DemoWalk.swift` | The demo walk and its map |

## Credit

Places and photos come from Wikipedia and OpenStreetMap through the brain's `GET /nearby`.
Cards say "From Wikipedia" (with a link) and "© OpenStreetMap contributors" where it applies.

## Not yet

- The pop-up's 8 s countdown and "why" face are on the phone and, from the Hardware tab's next
  flash, on the badge; the two are not kept in step.
- The learning signals (Going in, Not my thing...) and the onboarding's pace, time and "how
  often" reach the brain and are used by `/recommend` and `/ask`. The always-on watcher,
  which makes the picks the app shows, doesn't use them yet (`jensen/always-on.ts`).
- The laptop's Bluetooth bridge reads picks too, with its own cursor. When both the bridge
  and the phone are connected, the badge can get each pick twice.
