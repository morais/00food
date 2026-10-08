#!/usr/bin/env python3
"""Create an isolated simulator project using production UI and fictional fixtures.

Only temporary COPIES of app sources are adapted. No production target includes
fixtures or a demo switch. Run xcodegen/xcodebuild using the printed project path.
"""
import json
import pathlib
import shutil
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
output = pathlib.Path(tempfile.mkdtemp(prefix="00food-screenshot-", dir="/private/tmp"))
shutil.copytree(root / "Sources", output / "Sources", ignore=shutil.ignore_patterns("Widgets", "ZeroZeroFoodApp.swift"))
shutil.copytree(root / "Resources/App/Assets.xcassets", output / "Assets.xcassets")
for name in ("App.swift", "Fixtures.swift"):
    shutil.copy(root / "ScreenshotDemo" / name, output / "Sources" / name)


def replace_body(source, signature, body):
    """Replace one known Swift body; fail if the production signature changes."""
    assert source.count(signature) == 1, signature
    start = source.index("{", source.index(signature))
    depth = 1
    end = start + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[:start + 1] + "\n" + body + "\n    " + source[end - 1:]


path = output / "Sources/FoodStore.swift"
source = path.read_text()
source = replace_body(source, "    init()", '''        baseURL = "https://api.00food.com"
        token = "fictional-local-only"
        ScreenshotFixtures.configure(self)''')
for signature in ("    func refresh() async throws", "    func refreshConnections() async throws"):
    source = replace_body(source, signature, "        return")
source = replace_body(source, "    private func stage(", "        update()")
source = replace_body(source, "    private func call<T:",
                      '        throw FoodServiceError(message: "Screenshot demo: network access disabled")')
# No shared production keychain, even if an unrelated account button is tapped.
source = replace_body(source, "    private static func readToken()", '        return ""')
source = replace_body(source, "    private static func saveToken(",
                      '        throw FoodServiceError(message: "Screenshot demo: sign-in disabled")')
source = replace_body(source, "    private static func deleteToken()", "        return")
path.write_text(source)

path = output / "Sources/HealthEnergy.swift"
source = path.read_text()
for signature in ("    func connect()", "    func refresh()", "    func refreshWater()",
                  "    func logWaterCup()", "    func logWeight(", "    func enableDietaryExport(",
                  "    func syncDietaryEnergy(", "    func configureDietaryExport(", "    func setHistoryStart("):
    source = replace_body(source, signature, "        return")
source = replace_body(source, "    func waterMl(on", "        return Calendar.current.isDate(date, inSameDayAs: ScreenshotFixtures.now) ? 1500 : 1750")
source = replace_body(source, "    func dailyFeedbackHealth(", "        return []")
source = source.replace("var available: Bool { HKHealthStore.isHealthDataAvailable() }", "var available: Bool { false }")
path.write_text(source)

path = output / "Sources/ContentView.swift"
source = path.read_text().replace(
    "@State private var selectedLogDate = Calendar.current.startOfDay(for: Date())",
    '@State private var selectedLogDate = Calendar.current.startOfDay(for: ScreenshotFixtures.scenario == "review" ? ScreenshotFixtures.yesterday : ScreenshotFixtures.now)')
source = source.replace("@State private var showingSelectedFeedback = false",
                        '@State private var showingSelectedFeedback = ScreenshotFixtures.scenario == "review"')
path.write_text(source)
path = output / "Sources/QuickAddView.swift"
source = path.read_text().replace('@State private var selectedTab: FoodTab = .saved',
    '@State private var selectedTab: FoodTab = ScreenshotFixtures.scenario == "new-food" ? .new : .saved')
source = source.replace('@State private var descriptionText = ""',
    '@State private var descriptionText = ScreenshotFixtures.scenario == "new-food" ? "Small bowl: yogurt, berries & almonds" : ""')
path.write_text(source)
# Fixed clock only in the temporary copy, for reproducible dates and daily balance.
for path in (output / "Sources").glob("*.swift"):
    if path.name != "Fixtures.swift":
        path.write_text(path.read_text().replace("Date()", "ScreenshotFixtures.now"))

project = {
    "name": "ScreenshotDemo", "options": {"deploymentTarget": {"iOS": "27.0"}},
    "settings": {"base": {"SWIFT_VERSION": "5.10", "TARGETED_DEVICE_FAMILY": "1",
        "CODE_SIGNING_ALLOWED": "NO", "SUPPORTS_MACCATALYST": "NO"}},
    "targets": {"ScreenshotDemo": {"type": "application", "platform": "iOS",
        "sources": ["Sources", "Assets.xcassets"],
        "settings": {"base": {"PRODUCT_BUNDLE_IDENTIFIER": "com.00food.screenshots",
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor"}},
        "info": {"path": "Info.plist", "properties": {"CFBundleDisplayName": "00Food Demo",
            "FoodAppGroup": "group.com.00food.screenshots",
            "UILaunchScreen": {}, "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]}}}},
    "schemes": {"ScreenshotDemo": {"build": {"targets": {"ScreenshotDemo": "all"}}}},
}
(output / "project.json").write_text(json.dumps(project, indent=2))
print(output)
