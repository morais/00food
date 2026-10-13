# Health citations — App Review follow-up

## Audit

The rejected 1.0 build linked EFSA water guidance, WHO diet guidance and ACE
body-fat categories. It did not provide user-visible citations for the fallback
resting-energy equation, BMI range, fixed energy-to-weight approximation or
Forbes body-composition projection. Those links existed only in code comments
in some cases, which are not available to users.

## Where to find the sources in the revised app

| Information | User-visible citation access |
| --- | --- |
| Full reference list and explanation of each source | Settings → Health sources |
| Resting estimate, Health energy and allowance calculation | Expand the kcal-left balance → Calculation sources; Your details → either resting-energy (i) |
| BMI, weight forecast and Forbes fat/fat-free mass split | Progress & plans → Sources below the plan chart, or its (i) |
| Calories over time | Chart → Sources or (i) |
| Body-fat projection and ACE boundaries | Chart → Sources or (i) |
| Water goal | Water → (i) → EFSA link |
| 5-a-day goal and portion definition | 5 a day → (i) → WHO and NHS links |
| Daily-review general nutrition guidance | Under a completed review → Nutrition sources |
| Onboarding health references | Welcome → Health sources; Just the essentials → Calculation & reference sources; Choose your pace → plan chart Sources |

References: Mifflin and St Jeor (1990); Apple HealthKit definitions of resting
and active energy; CDC adult BMI categories; Hall (2008) on the limitations of
the traditional energy-to-weight rule; Hall (2007) on Forbes's model; ACE's
body-fat category chart; EFSA (2010); WHO Healthy diet; NHS 5 A Day portion sizes.

The source page explains which parts are app assumptions. Deficit percentages
are user-selected controls rather than medically recommended restriction levels.
The fallback substitutes age 35 and a midpoint offset for Neutral. Smoothing
and fixed-expenditure forecasts are app choices, not validated personalised
predictions. No calculations were changed as part of this citation update.

For future daily reviews, the MCP context includes reference URLs and instructions
to cite general health/nutrition recommendations using clickable Markdown links.
Previously saved reviews retain their original wording; the app displays the
general nutrition references beneath them. A connected agent remains responsible
for citing additional claims accurately.

## Draft response to App Review

We have added user-visible source citations for the app's health calculations
and guidance. Settings now includes a Health sources page listing the references,
links to the original sources, and an explanation of how each is used.

Sources are also accessible directly beside the relevant information: expand
the kcal-left balance and tap Calculation sources; open Sources or the (i) on
each Progress & plans chart; tap the (i) beside the resting estimates in Your
details, Water, or 5 a day; or tap Nutrition sources beneath a daily review.
The same references are accessible during onboarding and pace selection.

We explicitly distinguish published reference information from app assumptions,
and identify the charts as illustrations rather than predictions or diagnoses.
