#!/usr/bin/env python3
"""Copy production Watch views/models into an isolated, offline screenshot app."""
import json
import pathlib
import shutil
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path(tempfile.mkdtemp(prefix="00food-watch-screenshot-", dir="/private/tmp"))
sources = output / "Sources"
sources.mkdir()
for relative in ("Watch/WatchViews.swift", "WatchShared/WatchModels.swift", "Models.swift",
                 "ForbesBodyComposition.swift", "MeasurementUnits.swift", "ActiveDayProgress.swift"):
    shutil.copy(root / "Sources" / relative, sources / pathlib.Path(relative).name)
for name in ("App.swift", "Fixtures.swift", "Store.swift"):
    shutil.copy(root / "WatchScreenshotDemo" / name, sources / name)
shutil.copytree(root / "Resources/Watch/Assets.xcassets", output / "Assets.xcassets")

path = sources / "WatchViews.swift"
source = path.read_text()
changes = {
    "@State private var path: [WatchRoute] = []":
        "@State private var path: [WatchRoute] = WatchScreenshotFixtures.route.flatMap(WatchRoute.init(rawValue:)).map { [$0] } ?? []",
    "@State private var quantityFood: FoodItem?":
        '@State private var quantityFood: FoodItem? = WatchScreenshotFixtures.scenario == "portion" ? WatchScreenshotFixtures.foods[0] : nil',
    "@State private var quantity = 1.0": "@State private var quantity = 1.5",
    '@State private var description = ""': '@State private var description = "Yogurt, berries & almonds"',
}
for old, new in changes.items():
    assert source.count(old) == 1, f"Production screenshot hook changed: {old}"
    source = source.replace(old, new)
assert source.count("clock.date") == 3, "Production clock hooks changed"
source = source.replace("clock.date", "WatchScreenshotFixtures.now")
path.write_text(source)

project = {
    "name": "WatchScreenshotDemo",
    "settings": {"base": {"SWIFT_VERSION": "5.10", "CODE_SIGNING_ALLOWED": "NO"}},
    "targets": {"WatchScreenshotDemo": {
        "type": "application", "platform": "watchOS", "deploymentTarget": "11.0",
        "sources": ["Sources", "Assets.xcassets"],
        "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.00food.watchscreenshots",
            "TARGETED_DEVICE_FAMILY": "4", "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor"}},
        "info": {"path": "Info.plist", "properties": {
            "CFBundleDisplayName": "00Food Demo", "WKApplication": True,
            "WKWatchOnly": True,
            "ITSAppUsesNonExemptEncryption": False,
        }},
    }},
    "schemes": {"WatchScreenshotDemo": {"build": {"targets": {"WatchScreenshotDemo": "all"}}}},
}
(output / "project.json").write_text(json.dumps(project, indent=2) + "\n")
print(output)
