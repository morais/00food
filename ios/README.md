# 00Food for iOS

SwiftUI app for iPhone and iPad, built with Xcode 27 and XcodeGen. The main screen shows today's rough balance, frequent foods for one-tap logging, pending agent estimates, and today's entries. Add searches saved foods first, then a short starter list. Unfamiliar foods can be saved with a manual estimate or sent as text/photo to a remote MCP agent for review.

```sh
cp project.yml.sample project.yml
# Set your Apple team, bundle ID, and FoodServerBaseURL in project.yml.
xcodegen generate --spec project.yml
open ZeroZeroFood.xcodeproj
```

The app App ID needs Sign in with Apple and HealthKit. It reads only `activeEnergyBurned` from Apple Health. It stores no Health samples in Cloudflare. The target in `project.yml.sample` uses example identifiers; the real project file is ignored.

For a simulator compile without signing:

```sh
xcodegen generate --spec project.yml.sample
xcodebuild -project ZeroZeroFood.xcodeproj -scheme ZeroZeroFood \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/DerivedData" CODE_SIGNING_ALLOWED=NO build
```

For TestFlight, create the app record in App Store Connect, use an App Store distribution provisioning profile with both capabilities, archive the release scheme, export an IPA, upload it to App Store Connect, and assign the processed build to an internal beta group.
