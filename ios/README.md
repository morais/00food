# 00Food for iOS

SwiftUI app for iPhone and iPad, built with Xcode 27 and XcodeGen. The main screen shows today's rough balance, frequent foods for one-tap logging, pending agent estimates, and today's entries. Add searches saved foods first, then a collapsed starter list. Unfamiliar foods can be saved with a manual estimate or sent with a description, a photo, or both to a remote MCP agent for review. The new-food form keeps its description field and attached-photo preview in one section. The description and photo are submitted atomically under the same pending-food ID so the agent can consider both.

```sh
cp project.yml.sample project.yml
# Set your Apple team, bundle ID, and FoodServerBaseURL in project.yml.
xcodegen generate --spec project.yml
open ZeroZeroFood.xcodeproj
```

The app App ID needs Sign in with Apple and HealthKit. It reads `activeEnergyBurned`, `bodyMass`, and `bodyFatPercentage` from Apple Health. Active energy and historical measurements stay on device. The user can choose to import the displayed weight into their 00Food profile, which is stored in Cloudflare. Progress and plans opens from the toolbar beside Settings. It shows only the saved plan by default; Other plans expands gentle (300), steady (450), and faster (600 kcal/day) alternatives for comparison and switching. The charts run over six calendar months, with illustrative weight lines and actual weight/body-fat history since account creation. The weight axis starts at the weight corresponding to adult BMI 18.5; a shaded band reaches BMI 24.9, and a date appears when an estimate enters that band. The body-fat chart marks ACE's 25% male or 32% female classification boundary according to the selected estimate setting; neutral shows no category line. BMI is a screening measure, and the forecasts are directional. The allowance adds Health active energy once; exercise minutes are not converted to calories. The target in `project.yml.sample` uses example identifiers; the real project file is ignored.

The home screen's food log date control and arrows show previous days. Swipe an entry to delete it. Swipe a frequent food to hide it from the home screen; logging it again from Add restores it. The balance card shows the resting estimate and effective calorie gap in parentheses, plus how many estimates are still pending; pending calories are excluded. The snapshot currently supplies the last 90 days of logs. In Add, "Choose from Photos" and "Take photo" occupy separate rows so they open the intended library or camera control.

For a simulator compile without signing:

```sh
xcodegen generate --spec project.yml.sample
xcodebuild -project ZeroZeroFood.xcodeproj -scheme ZeroZeroFood \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/DerivedData" CODE_SIGNING_ALLOWED=NO build
```

For TestFlight, create the app record in App Store Connect, use an App Store distribution provisioning profile with both capabilities, archive the release scheme, export an IPA, and upload it to App Store Connect. Set `MARKETING_VERSION` to `1.0` and `CURRENT_PROJECT_VERSION` to the Lisbon local build timestamp (`TZ=Europe/Lisbon date +%Y%m%d%H%M`) before archiving, as in 00Todo. Once Apple finishes processing, `scripts/assign-testflight.py --app-id APP_ID --group-name Internal --build BUILD_NUMBER` creates or finds the app's internal group, assigns the build, and verifies the relationship. Add existing internal testers on the group's Testers page in App Store Connect. Set `ASC_KEY_PATH` to the App Store Connect API key when `~/.appstoreconnect/private_keys` contains more than one key; the Sign in with Apple key is separate.
