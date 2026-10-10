# Apple Watch screenshot demo

`../scripts/prepare-watch-screenshot-demo.py` creates a temporary, unsigned
watchOS simulator project from copies of production Watch views and models.
Its separate bundle ID is `com.00food.watchscreenshots`. The screenshot-only
store has no WatchConnectivity, disk, widget, haptic, Health, or network access;
saving is disabled. Production app targets never include these files.

The copied UI is adapted only to select a route, open the existing portion
sheet, seed text/quantity, and fix its clock at October 7, 2026, 18:41 UTC.
The fixtures contain fictional foods, balance/water values, and estimate states.
They are marketing examples, not actual agent responses or review evidence.
The balance scene has no estimate requests, so the production home view omits
its Food estimates button. The estimates scene retains the two sample requests.

Scenes: `overview`, `library`, `portion`, `water`, `estimates`, and optionally
`describe`. Pass `--scene <name>` when launching the simulator app.
The private marketing pipeline in `../00food-www/marketing/screenshots/` owns
capture, checksums, promotional composition, and generated artifacts. It removes
the demo app after capture. No device installation or App Store upload is needed.
