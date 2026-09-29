# Pricing and business models of third-party EV companion apps (benchmark for a premium Kia/Hyundai iOS app), as of Sept 2026

Research date: 2026-09-29. Prices were taken from live pricing pages and App Store listings fetched on that date unless flagged. Search-snippet-only figures are marked "(snippet)".

## Summary benchmark table

| App | Brands | Model | Price points (region) | What's in paid tier | Trial | Traction | Source |
|---|---|---|---|---|---|---|---|
| Tessie | Tesla | Paid subscription, 3 tiers, plus lifetime | Basic $6.99/mo, $69.99/yr, $199.99 lifetime; Pro $12.99/mo, $129.99/yr, $299.99 lifetime; Fleet $19.99/mo (US, per vehicle). UK App Store: Basic £6.99, Pro £12.99, lifetime £199.99, annual options £49.99–£129.99 | Basic: drive/charge tracking, alerts, Watch, widgets, API, basic battery tracking. Pro adds detailed battery tracking, sentry tracking, automations, firmware alerts, OBD profiler | Free trial (length not stated); "Happiness Guarantee" refund | 4.7/5 from 998 ratings (UK App Store); claims 500k+ drivers and fleet managers; 400k users cited Nov 2024 | [tessie.com/pricing](https://tessie.com/pricing), [UK App Store](https://apps.apple.com/gb/app/tessie-for-your-tesla/id1496718223), [Electrek](https://electrek.co/2024/11/28/tesla-releases-api-pricing-dev-says-would-cost-60-million-per-year-to-run-his-3rd-party-app/) |
| Stats (for Tesla) | Tesla | Subscription + lifetime + à la carte IAPs | $9.99/mo, $100/yr, $249.99 lifetime; add-ons $4.99–$14.99 (US) | Battery health, phantom drain, charging history, scheduling, widgets, Watch, Siri Shortcuts, dashcam viewer, export | 7-day (snippet) | 4.4/5 from 3,900 ratings (US) | [US App Store](https://apps.apple.com/us/app/quicktesla/id1191100729) |
| TeslaFi | Tesla | Paid only (web logger) | $7.99/mo, $79.99/yr (US) | Data logging | 14 days, no card needed | n/a | [teslafi.com](https://www.teslafi.com/signup.php) |
| Teslascope | Tesla | Freemium, 3 tiers | Community free; Plus $3.99/mo ($39.99/yr); Pro $6.99/mo (US, per vehicle) (snippet) | Plus: drive/charge history, cost calc with ToU tariffs. Pro: automations, Supercharger costs/invoices, driver mgmt | n/a | API fees would be ~7.5x its monthly revenue (Nov 2024), so it is a small business | [search snippet / teslascope.com/membership](https://teslascope.com/membership), [Electrek](https://electrek.co/2024/11/28/tesla-releases-api-pricing-dev-says-would-cost-60-million-per-year-to-run-his-3rd-party-app/) |
| TezLab | Tesla, Rivian (no Hyundai/Kia found) | Freemium + Pro subscription | Pro $5.99/mo; extra vehicles $3.99/mo or $19.99/yr (US) (snippet) | Pro features, AI "car reports" | n/a | n/a | [tezlabapp.com/subscribe](https://tezlabapp.com/subscribe), [TechCrunch](https://techcrunch.com/2024/10/09/tezlab-launches-new-ai-powered-car-reports-for-tesla-and-rivian-evs/) |
| Rivian Roamer | Rivian | Freemium | Plus $4.99/mo or $54.99/yr (US); one sub covers all vehicles | Free: live dashboard, software update alerts, leaderboards. Plus: mapped drives with costs, charging curves/costs, efficiency by temp/speed/tyre, battery capacity trend, phantom drain, CSV export, imports from ABRP/TezLab | 14-day full refund | Not disclosed | [rivianroamer.com/plus](https://rivianroamer.com/plus) |
| TRONITY | Multi-brand, including Kia/Hyundai via OEM API | Freemium consumer app + B2B fleet | Basic free; Premium €4.90/€6.90; Professional €14.90/€16.90 per month per vehicle (DE, incl. 19% VAT; likely annual-billed vs monthly-billed, see note). Fleet from €5/vehicle/mo | Premium: automatic trip and charge detection, diagnostics. Pro: German tax-compliant logbook, payroll home-charging reports | 14 days | n/a | [tronity.io app pricing](https://www.tronity.io/en/tronity-app/pricing), [fleet pricing](https://www.tronity.io/en/fleet-management/pricing) |
| ABRP (Rivian-owned) | Multi-brand | Freemium routing | £4.99/mo or £39.99/yr (UK App Store); ~$50/yr US (snippet) | Live traffic/weather, charger availability, CarPlay/Android Auto nav, multi-vehicle, drive/charge history, Apple Watch | n/a | 4.5/5 from ~1,000 ratings (UK) | [UK App Store](https://apps.apple.com/gb/app/a-better-routeplanner-abrp/id1490860521), [ABRP premium](https://abetterrouteplanner.com/premium/) |
| Zapmap | Charging map (UK) | Freemium + charging payments | Premium £7.99/mo or £47.99/yr (snippet) | 5% off charging via Zap-Pay (first 50 kWh/mo), CarPlay/AA, multi-car, ad-free, unlimited routes | n/a | n/a | [smarthomecharge review](https://www.smarthomecharge.co.uk/reviews/zap-map-plus-and-premium-review/), [Zapmap plans](https://www.zapmap.com/app/plans-compared) |
| BetterBlue | Kia/Hyundai (iOS) | Open source (free) | Free | Remote lock/climate, status, widgets, Apple Watch, Siri/Shortcuts | — | n/a | [markschmidt.io](https://markschmidt.io/betterblue.html), [GitHub](https://github.com/schmidtwmark/BetterBlue) |

## Tesla third-party apps: prices, tiers, trials, traction

### Takeaway
The mature Tesla market has settled at about **$4–8/month or $40–80/year for a core logging tier**, with **$10–13/month or $100–130/year for power tiers**. Lifetime unlocks sit at **roughly 2.5–3x the annual price** ($199–$300). Tessie is the category leader, with ~500k claimed users and a 4.7-star rating.

### Cited Findings
- Tessie: Basic $6.99/mo, $69.99/yr, $199.99 lifetime; Pro $12.99/mo, $129.99/yr, $299.99 lifetime; Fleet $19.99/mo; all per vehicle, up to 5 vehicles. Its marketing line is "Starting at just 19 cents per day", backed by a refund "Happiness Guarantee" — [Tessie pricing](https://tessie.com/pricing)
- Tessie's feature split: every plan gets web + mobile + smartwatch apps, drive and charge tracking, alerts, integrations, API and basic battery tracking. Pro adds detailed battery tracking, self-driving stats, sentry tracking, software/firmware alerts, automations and the OBD profiler — [Tessie pricing](https://tessie.com/pricing)
- Tessie on the UK App Store: 4.7/5 (998 ratings). IAPs are £6.99 Basic, £12.99 Pro, £199.99 lifetime and annual options £49.99–£129.99. Features include Watch, Lock Screen live charging widget and Live Activities. Some reviewers find the subscription costly compared with the free Tesla app — [UK App Store](https://apps.apple.com/gb/app/tessie-for-your-tesla/id1496718223)
- Tessie's site claims it is "trusted by over 500,000 Tesla drivers and fleet managers" (search snippet). In Nov 2024 the founder said 400,000 users would cost ~$60M/yr under Tesla's Fleet API pricing — [tessie.com](https://www.tessie.com/), [Electrek](https://electrek.co/2024/11/28/tesla-releases-api-pricing-dev-says-would-cost-60-million-per-year-to-run-his-3rd-party-app/)
- Tessie has no recorded funding rounds (bootstrapped), per Tracxn (search snippet) — [Tracxn](https://tracxn.com/d/companies/tessie/__bJdGsESl_K-P3Zk1iE4i7YBJujroLEn5zNxyBnrZrt8)
- Stats: $9.99/mo, $100/yr, $249.99 lifetime, plus one-off add-ons (Trip Recorder $14.99, Dash-cam $14.99, Max Range Compare $14.99, Solar Charging $4.99). Rated 4.4/5 from 3,900 US ratings — [US App Store](https://apps.apple.com/us/app/quicktesla/id1191100729)
- Stats moved early lifetime buyers onto subscription, which caused a backlash on owner forums — [Cybertruck Owners Club](https://www.cybertruckownersclub.com/forum/threads/%E2%80%9Cstats%E2%80%9D-now-forcing-subscription-on-early-adopters.31969/page-2)
- TeslaFi: $7.99/mo or $79.99/yr, with a 14-day free trial and no payment details needed — [TeslaFi](https://www.teslafi.com/signup.php)
- Teslascope: free Community tier; Plus $3.99/mo ($39.99/yr); Pro $6.99/mo per vehicle. Pro adds automations and Supercharger invoices (search snippet) — [Teslascope membership](https://teslascope.com/membership)
- Teslascope's developer said Tesla's API fees would be ~7.5x the app's monthly revenue — [Electrek](https://electrek.co/2024/11/28/tesla-releases-api-pricing-dev-says-would-cost-60-million-per-year-to-run-his-3rd-party-app/)
- TezLab Pro: $5.99/mo; extra vehicles $3.99/mo or $19.99/yr (search snippet). TezLab supports Tesla and Rivian; no Kia/Hyundai support found — [TezLab subscribe](https://tezlabapp.com/subscribe), [TechCrunch 2024](https://techcrunch.com/2024/10/09/tezlab-launches-new-ai-powered-car-reports-for-tesla-and-rivian-evs/)

### Inferences
- Tessie's price ladder (~$7 core, ~$13 pro, lifetime ~2.9x annual on Basic) is the strongest proven anchor. Its UK App Store GBP prices match the USD numbers (£6.99 = $6.99), so UK buyers pay more in real terms and still rate it 4.7.
- Power-tier features are automations, detailed battery analytics, sentry/security tracking and firmware alerts. Logging, alerts, Watch and widgets are in the base tier.
- For Tesla apps the platform (OEM API) cost is an existential risk. Kia/Hyundai apps face the same kind of risk from unofficial API changes and rate limits.

### Gaps
- "Watch app for Tesla" / Nikola / Teri watch apps: I found an App Store listing for Teri ([App Store](https://apps.apple.com/app/id1583902261)) but did not verify its prices or ratings.
- No public revenue figures for Tessie, Stats or TeslaFi. The Sensor Tower estimates are paywalled.
- Tessie's trial length is not stated on its pricing page.

## Non-Tesla / multi-brand apps and how they make money

### Takeaway
Non-Tesla apps charge **less** than Tesla apps: about **$5/€5/£5 per month and $40–55/£40–48 per year**. They usually use **freemium** with a useful free tier. Money comes from three places: consumer subscriptions (Roamer, TRONITY Premium, ABRP, Zapmap), B2B fleet/tax-logbook features (TRONITY Professional/Fleet, Tessie Fleet) and charging-payment margins (Zapmap Zap-Pay). The only Kia/Hyundai-specific native iOS app I found, BetterBlue, is free and open source. That leaves the paid Kia/Hyundai niche largely unoccupied.

### Cited Findings
- Rivian Roamer: free dashboard (live status, software update alerts, leaderboards). Plus costs $4.99/mo or $54.99/yr and covers all of a user's Rivians. Plus adds mapped drives with costs, charging curves and costs, efficiency by temperature/speed/tyre, battery capacity trends, phantom drain, CSV export and imports from ABRP/ElectraFi/TezLab. There is a 14-day full refund, and history starts from the subscription date — [Roamer Plus](https://rivianroamer.com/plus)
- TRONITY consumer app: Basic free (manual logs, route planning, cost management); Premium €4.90 / €6.90 (automatic trip and charge detection, diagnostic reports); Professional €14.90 / €16.90 (tax-compliant logbook, payroll home-charging reports). Prices are per month, include German VAT, and come with a 14-day trial. The page lists the higher figure as "annual", which looks like a labelling error. My reading is €4.90 when billed annually and €6.90 when billed monthly, but this is unconfirmed — [TRONITY app pricing](https://www.tronity.io/en/tronity-app/pricing)
- TRONITY Fleet starts at €5/vehicle/mo, plus €15/mo per integration or fleet admin on annual plans (search snippet) — [TRONITY fleet pricing](https://www.tronity.io/en/fleet-management/pricing)
- A TRONITY help article notes Kia/Hyundai trips can show 0 kWh or too little consumption, a data-quality weakness (search snippet) — [TRONITY search result](https://www.tronity.io/en/home)
- ABRP (seller now Rivian): free app with Premium at £4.99/mo or £39.99/yr on the UK App Store; rated 4.5/5 from ~1,000 ratings. One reviewer called CarPlay "flakey" in a Kia — [UK App Store](https://apps.apple.com/gb/app/a-better-routeplanner-abrp/id1490860521)
- ABRP Premium costs ~$50/yr in the US, and forums cite about £5/€5 per month (search summary of forum posts) — [Speak EV thread](https://www.speakev.com/threads/abrp-premium-pricing.177612/), [Kia EV Forum](https://www.kiaevforums.com/threads/should-i-get-abrp-premium.3285/)
- ABRP Premium features: live traffic, weather, live charger availability, CarPlay/Android Auto navigation, speed cameras, multi-vehicle, drive and charge history, priority support, Apple Watch — [ABRP Premium](https://abetterrouteplanner.com/premium/)
- Zapmap Premium: £7.99/mo or £47.99/yr (£3.99/mo effective). It includes 5% off charging via Zapmap payment on the first 50 kWh/month, CarPlay/Android Auto, multi-car and no ads (search snippet; the official page 404'd on fetch) — [Smart Home Charge review](https://www.smarthomecharge.co.uk/reviews/zap-map-plus-and-premium-review/), [Zapmap plans compared](https://www.zapmap.com/app/plans-compared)
- BetterBlue: an open-source SwiftUI app for Kia Connect/Bluelink with widgets, an Apple Watch app and Siri/Shortcuts. It needs an active OEM connected-services subscription and warns about API rate limits — [BetterBlue](https://markschmidt.io/betterblue.html), [GitHub](https://github.com/schmidtwmark/BetterBlue)
- The Kia Connect official service is free for 7 years from first sale in Europe/UK. After that it is a paid "Premium" plan, priced by model (price not found) — [Kia Connect FAQ](https://connect.kia.com/eu/customer-support/faq/), [Kia Connect subscriptions](https://connect.kia.com/eu/product-information/ccs-subscriptions/)
- The official MyHyundai with Bluelink app already offers phone widgets and Apple Watch support in the US — [App Store](https://apps.apple.com/us/app/myhyundai-with-bluelink/id893514610)

### Inferences
- The closest analogues to a Kia/Hyundai app are Rivian Roamer ($4.99/$54.99) and TRONITY Premium (€4.90–6.90). Both are single-brand or multi-brand logbook apps in markets smaller than Tesla's, and both price at about half of Tessie Pro.
- Because Kia Connect is free for 7 years in UK/EU, owners are not used to paying for connectivity. The app has to justify its price on top of a free official app, so widgets and Watch alone are weak paywall features. BetterBlue gives those away for free.
- Business-mileage and tax logbook features (TRONITY Pro) earn about 3x the consumer price. A UK HMRC mileage/company-car home-charging reimbursement report could be a higher tier.

### Gaps
- Octopus Electroverse (free; monetised through charging-network interchange) was not verified this session.
- ChargePoint's consumer model was not researched (it is essentially hardware plus network, B2B).
- Smartcar-powered consumer apps and "Electrified" were not found.
- I found no third-party VW ID/Skoda/Polestar paid apps with published prices.
- Official Kia Connect Premium price after 7 years: not found.

## Features people pay for

### Takeaway
Across tiers, paid features cluster around **automatic drive and charge logging with costs (including time-of-use tariffs)**, **battery health/degradation and phantom-drain tracking**, **automations/scheduling**, and **security/sentry and firmware alerts**. Export, multi-vehicle and **CarPlay/Watch/widget/Live Activity surfaces** also show up in paid tiers. Remote controls and basic status are free-tier or OEM-app territory.

### Cited Findings
- Tessie's Pro-only features are detailed battery tracking, sentry tracking, software update tracking, firmware alerts, automations and the OBD profiler — [Tessie pricing](https://tessie.com/pricing)
- Teslascope Plus is built around history and cost calculations with ToU and location-based kWh rates. Pro adds automations and charging invoices — [Teslascope membership](https://teslascope.com/membership)
- Roamer Plus centres on costed drives and charges, charging curves, battery capacity trends, phantom drain and CSV export — [Roamer Plus](https://rivianroamer.com/plus)
- Stats sells battery health, phantom drain, scheduling, dashcam and export, and adds one-off feature IAPs on top of the subscription — [US App Store](https://apps.apple.com/us/app/quicktesla/id1191100729)
- TRONITY's paywall sits exactly at "automatic" logging; manual logging is free — [TRONITY app pricing](https://www.tronity.io/en/tronity-app/pricing)
- ABRP and Zapmap put CarPlay/Android Auto, live data and multi-vehicle behind the paywall — [ABRP Premium](https://abetterrouteplanner.com/premium/), [Smart Home Charge review](https://www.smarthomecharge.co.uk/reviews/zap-map-plus-and-premium-review/)

### Inferences
- A natural split: the free tier covers remote controls, status, a basic widget and maybe Watch. Premium covers automatic charge ledger and costs with Octopus/Agile tariffs, smart-charge planner, battery-health history, alerts and automations, Live Activities and complications, and export.

### Gaps
- No survey data ranking which features EV owners value most.

## Conversion, willingness to pay and price anchors

### Takeaway
The anchors are **~£/$/€4.99 per month, ~£40–55 per year (about 2 months free), and lifetime at ~2.5–3x annual**. General subscription benchmarks favour a hard paywall or long trial: 17–32 day trials convert about 42% to paid, against about 25% for trials under 4 days.

### Cited Findings
- RevenueCat State of Subscription Apps 2026: hard paywalls reach 10.7% median download-to-paid by day 35, against 2.1% for freemium. Revenue per install at day 60 is $3.09 (hard paywall) vs $0.38 (freemium) — [RevenueCat 2026 benchmarks](https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026)
- The same report puts median trial-to-paid at 42.5% for 17–32 day trials and 25.5% for trials of 4 days or less. 55.4% of 3-day-trial cancellations happen on day 0 — [RevenueCat 2026 benchmarks](https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026)
- Also from that report: 72% of annual subscribers cancel within year 1 (up from 56% in the 2025 report), and 35% of annual cancellations happen in month 1. Apple billing failures cause 14% of cancellations vs 31% on Google Play — [RevenueCat 2026 benchmarks](https://www.revenuecat.com/blog/growth/subscription-app-trends-benchmarks-2026)
- RevenueCat 2025: download-to-trial is 9.8% for high-priced apps vs 4.3% for low-priced apps (search snippet) — [RevenueCat 2025](https://www.revenuecat.com/state-of-subscription-apps-2025)
- Observed EV-app anchors: $4.99/mo (Roamer, ABRP/£4.99), $5.99 (TezLab), $6.99 (Tessie Basic, Teslascope Pro), $7.99 (TeslaFi, Zapmap £7.99), $9.99–12.99 (Stats, Tessie Pro). Annual prices run £39.99 (ABRP), £47.99 (Zapmap), $54.99 (Roamer), $69.99–$79.99 (Tessie Basic, TeslaFi), $100–$130 (Stats, Tessie Pro). Lifetime ranges $199.99–$299.99 (Tessie, Stats) — sources in table above
- A Facebook VW group thread asked "Is paying $4.99 per month worth it for the ABRP app", a sign that $4.99 is where non-Tesla owners start to question value (search result title only) — [Facebook group](https://www.facebook.com/groups/666960357264469/posts/1467156883911475/)

### Inferences
- A defensible UK launch position for a Kia/Hyundai premium app: **£3.99–4.99/month, £34.99–39.99/year, with an optional £79.99–99.99 lifetime**. That undercuts Tessie Basic and matches ABRP/Roamer. The price has to cover a free official app plus free BetterBlue, and a smaller, less affluent owner base than Tesla's.
- Use a 14-day or longer trial, which matches TeslaFi, TRONITY and Roamer and fits RevenueCat's longer-trial data.
- The Stats backlash is a caution on lifetime: price it knowing it may need honouring indefinitely, and budget for API-break risk.

### Gaps
- No EV-specific conversion or willingness-to-pay survey found.
- No public subscriber or revenue numbers for any EV companion app other than Tessie's user count.
