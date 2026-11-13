# Jensen, the phone app

A SwiftUI app for iPhone (iOS 26). It opens as a chat:

1. Jensen interviews you: what you're into, how you like to explore.
2. It asks for your location (the system's question comes up from inside the chat).
3. From then on it keeps looking for places around you that fit, and pushes each one into
   the chat with a picture and to the badge over Bluetooth. It goes on with the phone in a
   pocket.

## Demo walk

The "Demo walk" button (top left) walks for you: Apple Maps' walking route from the Ferry
Building to Coit Tower, stepped along at walking pace (1.4 m/s), with a 1x / 5x / 20x
switch and a map showing the route and where the walk is. Each step is handed to the place
finder exactly like a position from the phone's GPS, so Jensen finds places along the way,
and it is sent to the Jensen server when one is set. It works on a real iPhone with no
Xcode attached. The interview has to be done first; the location question does not.

Launching with `-demoWalk 20` sets off at once at that speed:
`xcrun simctl launch booted com.kradllit.jensen -demoWalk 20`.

In the simulator the system's own way works too:
`xcrun simctl location booted start --speed=1.4 37.7955,-122.3937 37.8024,-122.4058`.

## The Jensen server

Menu (top right), "Jensen server": the address where `jensen/server.ts` runs, for example
`http://192.168.1.20:8787` for a computer on the same Wi-Fi (the simulator starts with
`http://localhost:8787`). While it is set, the app introduces the walker (POST /profile,
with the interview's answers) and reports every position, real or demo (POST /location).
The app does not pick up what the server chooses (GET /badge/next) yet.

## Run it

Open `Jensen.xcodeproj` in Xcode 27, pick a simulator or your iPhone, press Run. On a phone,
choose your own team under Signing & Capabilities first; no team is saved in the project.

From the command line:

```sh
xcodebuild -project Jensen.xcodeproj -scheme Jensen \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
xcrun simctl boot "iPhone 18 Pro"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Jensen.app
xcrun simctl location booted set 37.7955,-122.3937     # somewhere to look around
xcrun simctl launch booted com.kradllit.jensen
```

The project file is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After adding or removing a file, run `xcodegen` in this folder and commit the result.

## The code

| File | What |
|---|---|
| `Jensen/Jensen.swift` | Jensen: the interview, then the loop that looks for places and pushes them |
| `Jensen/PlaceFinder.swift` | Where the phone is and what is around it (Apple's MapKit), and a place's picture |
| `Jensen/BadgeLink.swift` | The Bluetooth link to the badge (`badge/src/ble.rs` is the other end) |
| `Jensen/DemoWalk.swift` | The demo walk and its map |
| `Jensen/BrainLink.swift` | The link to the Jensen server |
| `Jensen/ChatView.swift` | The chat screen |

## What it does not do yet

- **The places in the chat are not the server's.** The interview is scripted and the places
  shown come from Apple's maps search, matched to your words by a small table in
  `PlaceFinder.swift`. The server gets the positions and makes its own choices, but the app
  does not show those yet.
- **The badge gets text, not the picture.** The badge's firmware shows a line of text sent
  over Bluetooth (the place's name and distance, for six seconds). Showing a picture needs
  new firmware: receive an image over Bluetooth and draw it. The app already makes the
  picture at the badge's size (466 x 466) and shows it round in the chat.
- **Pictures are street-level photos where Apple has them, a map of the spot otherwise.**
  In the simulator it has always been the map.
- **The simulator has no Bluetooth**, so the badge link shows "Bluetooth off" there. The
  badge needs a real iPhone.
- The link takes the first badge it finds; the badge has no pairing.
