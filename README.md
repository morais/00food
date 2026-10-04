# 00Food

00Food is a small iOS calorie log built as a sibling to [00Todo](https://github.com/morais/00todo). It favors directional values and fast repeat logging: a previously logged food takes one tap to add again. New foods can be entered manually or sent with a description, photo, or both to a connected MCP agent. The agent checks the submitted description and photo together, proposes an estimate, and the person reviews it before it becomes a reusable food and a log entry.

The iOS app is SwiftUI. The backend is a Cloudflare Worker with D1 for account and food data and a private R2 bucket for photos awaiting review. Native Sign in with Apple connects to the Worker. Apple Health active energy, weight, and body-fat percentage are read on device. The latest Health weight can be reviewed and imported into the account profile. The rough daily balance is a weight-loss target based on a resting estimate from height, weight, and an estimate setting, plus today's Health active energy, minus logged food. Exercise minutes are not converted to a second calorie credit. Three calorie-gap levels show directional eight-week illustrations beside actual Health weight and body-fat history from account creation. These are guides, not clinical predictions.

The food log can browse previous dates, with individual entries removable from the selected day. Progress charts display the adult BMI 18.5–24.9 weight band for the saved height, begin their weight axis at the BMI 18.5 weight, and mark 25% on the body-fat chart as a reference.

## Development

- [iOS setup](ios/README.md)
- [Worker setup](server/README.md)
- [Brand assets](docs/brand/README.md)

Production identifiers, signing settings, database IDs, and credentials live in ignored `ios/project.yml` and `server/wrangler.toml`. The committed `.sample` files are examples. The iOS marketing version is `1.0`; release builds use a local Lisbon timestamp in `YYYYMMDDHHmm` format, matching 00Todo.

## Production

The API is deployed at `https://api.00food.com` as the `00food-api` Cloudflare Worker. The iOS app uses `com.00food.app` and its native Sign in with Apple capability; MCP web sign-in uses the `com.00food.app.signin` Services ID. Internal TestFlight builds are distributed from App Store Connect app `6818843517` to the `Internal` group. Cloudflare and Apple credentials are provisioned outside this repository.

## Privacy and data

The Worker stores an Apple account identifier, optional relay email, profile measurements, foods, logs, and pending estimates. A submitted photo is private in R2 and is deleted when the estimate is accepted or discarded, or when the account is deleted. MCP agents can see saved foods and pending food text/photos only after Apple OAuth consent. They can propose estimates but cannot directly log food or read Health data. Apple Health history stays on the iPhone; only a weight explicitly chosen for the account profile is uploaded. App and MCP credentials are separate opaque tokens stored as hashes in D1. The iOS app keeps its app credential in Keychain.

The source code is MIT licensed. The 00Food name and visual assets have a separate [brand license](docs/brand/LICENSE).
