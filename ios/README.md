# Jensen, the phone app

A SwiftUI app for iPhone (iOS 26). It opens as a chat:

1. Jensen interviews you: what you're into, how you like to explore.
2. It asks for your location (the system's question comes up from inside the chat).
3. From then on it keeps looking for places around you that fit, and pushes each one into
   the chat with a picture and to the badge over Bluetooth. It goes on with the phone in a
   pocket.

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
| `Jensen/ChatView.swift` | The chat screen |

## What it does not do yet

- **No model behind it.** The interview is scripted and places come from Apple's maps
  search, matched to your words by a small table in `PlaceFinder.swift`. A key for Claude
  must not ship inside an app, so Claude would sit behind a server the app talks to.
- **The badge gets text, not the picture.** The badge's firmware shows a line of text sent
  over Bluetooth (the place's name and distance, for six seconds). Showing a picture needs
  new firmware: receive an image over Bluetooth and draw it. The app already makes the
  picture at the badge's size (466 x 466) and shows it round in the chat.
- **Pictures are street-level photos where Apple has them, a map of the spot otherwise.**
  In the simulator it has always been the map.
- **The simulator has no Bluetooth**, so the badge link shows "Bluetooth off" there. The
  badge needs a real iPhone.
- The link takes the first badge it finds; the badge has no pairing.
