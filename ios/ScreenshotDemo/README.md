# Local screenshot demo

The samples in `Fixtures.swift` are fictional, including the calorie estimates,
agent replies and Health values. They are illustrative content, not responses
from a live agent or verified nutrition records.

The shipping Xcode project includes `Sources`, not `ScreenshotDemo`. The helper
copies production SwiftUI screens into a temporary simulator project with its
own bundle ID (`com.00food.screenshots`). It substitutes the store initializer,
disables all service requests and keychain access, and substitutes Health entry
points so no Health records are queried or written. It also uses a fixed clock
for repeatable captures. Production sources are never modified by the helper.

Prepare and build from the repository root (Xcode 27 and XcodeGen required):

```sh
python3 ios/scripts/prepare-screenshot-demo.py
# cd to the temporary directory printed above
xcodegen generate --spec project.json
xcodebuild -project ScreenshotDemo.xcodeproj -scheme ScreenshotDemo \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/00food-screenshot-derived-data \
  CODE_SIGNING_ALLOWED=NO build
```

Install `Build/Products/Debug-iphonesimulator/ScreenshotDemo.app` from the derived
data directory using `xcrun simctl install DEVICE APP_PATH`. Launch with:

```sh
xcrun simctl launch --terminate-running-process DEVICE com.00food.screenshots --scene overview
```

Scenes: `overview`, `library`, `new-food`, `estimate`, `clarification`, `review`, `sign-in`, `setup`.
They render the existing app screens; only initial state and data are seeded.
The reviewed yogurt bowl goes from 190 to 230 kcal after adding two teaspoons of
honey. Neither unapproved estimate is included in the log. Today totals 1,465
kcal; yesterday totals 1,715. The fictional resting estimate is 1,850 kcal and
active energy is 420, giving 805 kcal remaining today with a zero calorie gap.

Promotional captures install the demo on a simulator with a fixed status bar,
capture each scene, and uninstall it. Never install this demo onto a physical
device or upload its binary to TestFlight.
