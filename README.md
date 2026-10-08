# 00Food

**Your food log. Your AI agent.**

00Food is an iPhone food log built for you and your AI agent, and a sibling to [00Todo](https://github.com/morais/00todo). Connect your favourite compatible MCP agent to estimate new foods from descriptions or photos and help you review your day. You approve the estimates and build your own reusable food library. There is no built-in food catalogue or bundled AI agent; manual logging and fast repeat logging are always available.

ChatGPT Work is the recommended setup for automatic responses through MCP Events. Connecting the server and subscribing to events are separate steps: the app's **Connect your agent** guide provides copyable instructions and shows connection and event-subscription status. Other compatible agents can check pending requests when asked. See the [agent setup guide](docs/agent-setup.md) for setup, optional daily reviews, and compatibility details.

The iOS app is SwiftUI. The backend is a Cloudflare Worker with D1 for account and food data and a private R2 bucket for photos awaiting review. Native Sign in with Apple connects to the Worker. Apple Health active energy, weight, body-fat percentage, and water are read on device. The latest Health weight can be reviewed and imported into the account profile; Settings also allows a manual weight entry that is written to Health and the profile. Eight cups under Log Food show progress toward two liters of water, and tapping one writes 250 mL to Health. Foods carry a rough fruit-and-vegetable portion count per serving, proposed by the agent or set manually. Today shows progress capped at five portions. The rough daily balance is a weight-loss target based on a resting estimate from height, weight, an estimate setting, and optional birth year, plus today's Health active energy, minus logged food. A small track on the balance card compares the portion of a configurable active day elapsed with the portion of the current allowance eaten. Exercise minutes are not converted to a second calorie credit. Three calorie-gap levels show directional six-month illustrations beside actual Health weight and body-fat history from account creation. These are guides, not clinical predictions.

The food log can browse previous dates, with individual entries removable by swipe. The Home Screen menu has Log food and Log with camera actions. The Log food screen prioritizes previously saved foods; new foods are estimated by the connected agent or entered manually, without a starter list. Progress and plans opens from the toolbar beside Settings. It shows the saved plan first; expanding Other plans reveals alternatives that can be selected. Its charts show six calendar months of directional estimates, display the adult BMI 18.5–24.9 weight band for the saved height, begin their weight axis at the BMI 18.5 weight, and report the estimated date when a line enters that range. The body-fat chart marks the [ACE classification boundary](https://www.acefitness.org/continuing-education/certified/october-2018/7086/ace-sponsored-research-can-the-leanscreen-app-accurately-assess-percent-body-fat-and-waist-to-hip-ratio/) for the selected estimate setting: 25% for male, 32% for female.

## Development

- [iOS setup](ios/README.md)
- [Worker setup](server/README.md)
- [Brand assets](docs/brand/README.md)

The official app uses the hosted Worker at `https://api.00food.com`. Deployment config is gitignored; `server/wrangler.toml.sample` and `ios/project.yml.sample` are generic templates for your own deployment. Credentials are provisioned outside this repository.

## Privacy and data

The Worker stores an Apple account identifier, optional relay email, profile measurements, optional birth year, foods, logs, and pending estimates. A submitted photo is private in R2 and is deleted when the estimate is accepted or discarded, or when the account is deleted. MCP agents can see saved foods and pending food text/photos only after Apple OAuth consent. They can propose estimates but cannot directly log food. Apple Health history stays on the iPhone unless the user enables automatic Daily feedback or requests missing days manually. Each request uploads up to seven completed days of available daily Health aggregates (water, active and resting energy, weight, and body fat) to the private account with a feedback request. An agent with newly granted `daily:read` access can inspect those aggregates with the day's food logs, then save a review with `daily:write`. Disabling the option stops automatic requests; earlier reviews remain until account deletion. A weight explicitly chosen for the account profile is also uploaded. App and MCP credentials are separate opaque tokens stored as hashes in D1. The iOS app keeps its app credential in Keychain.

## License

Source code is MIT licensed; see [LICENSE](./LICENSE).

The 00Food name, logos, icons, wordmarks, mascot, and other brand artwork,
including the files in `docs/brand` and the app assets generated from them,
are excluded from the MIT License and governed by
[docs/brand/LICENSE](./docs/brand/LICENSE). No trademark rights are granted.
