# Tabata

Minimal native SwiftUI iOS and watchOS Tabata timer.

- Default workout: 8 rounds of 20 seconds work and 10 seconds rest, plus up to three custom presets.
- iPhone owns the timer.
- Watch mirrors the timer and sends start, pause, reset, and sound commands.
- Sounds beep during the final 5 work seconds and final 3 rest seconds, and work, rest and finish each have their own cue.
- Watch pairs sound cues with haptics.

Build:

```sh
~/.local/share/mise/installs/ruby/3.3.4/bin/ruby Tools/generate_project.rb
xcodebuild build -project Tabata.xcodeproj -scheme Tabata -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild -project Tabata.xcodeproj -target "Tabata Watch App" -configuration Debug -sdk watchos build CODE_SIGNING_ALLOWED=NO
swift test
```

Release setup:

- App Store/TestFlight setup is documented in [docs/APPSTORE_SETUP.md](docs/APPSTORE_SETUP.md).
- GitHub release tags use `vX.Y.Z`; the release workflow uploads the build to TestFlight and attaches the exported `.ipa` to the GitHub Release.
- `refresh-testflight.yml` rebuilds when the last release is 30 days old, because TestFlight builds expire after 90.
