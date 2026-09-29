# Official Kia app and third-party Kia/Hyundai EV companion apps (UK/EU focus, as of Sep 2026)

Research note: about 24 tool calls. Several forum pages (kiaevforums.com, speakev.com, kiaownersclub.co.uk) now redirect to a paywalled "tollbit" gateway (HTTP 402), so forum content below comes from search-result snippets rather than full reads. Treat those items as lower confidence. The Google Play listings for the Kia apps could not be fetched, so there are no Play ratings or install counts for the Kia App.

## Official Kia app (EU/UK "Kia App", formerly Kia Connect / UVO) and Hyundai Bluelink EU

### Takeaway
In EU/UK, the new "Kia App" (Kia Corporation, iOS id6740517042, Android `com.kia.oneapp.eu`) replaced the separate Kia Connect and Kia Charge apps. It covers remote climate, locks, windows, charging, schedules, digital key and an Apple Watch app. Connectivity is free for 7 years, and paid Kia Connect subscriptions launch from May 2026 at model-dependent prices that are published only inside the in-app Store. The UK App Store rating is a respectable 4.1 from 4,000+ ratings, but owners complain about a cluttered redesign, buried EV settings (charge limit), logouts and unreliable remote climate. Hyundai Bluelink Europe is rated much worse (about 1.8 on Android).

### Cited Findings
**App identity and platforms**
- The Kia App merges the former Kia Connect and Kia Charge apps into one app "for daily vehicle usage, charging and maintenance". — [Kia UK: Kia App](https://www.kia.com/uk/electric-hybrid-cars/technology/kia-app/)
- iOS listing (GB store, fetched Sep 2026): developer Kia Corporation, free, **4.1/5 from 4,000+ ratings**, v1.4.2 updated about 6 days before the fetch, 647.5 MB. It requires iOS 16+ and supports **watchOS 9+** and visionOS. Category Utilities, rank #111. — [App Store GB: Kia App](https://apps.apple.com/gb/app/kia-app/id6740517042)
- Android package is `com.kia.oneapp.eu`. The rating and install count could not be retrieved (fetch failed). — [Google Play: Kia App](https://play.google.com/store/apps/details?id=com.kia.oneapp.eu)
- The legacy EU "Kia Connect" iOS app (id1577334573) still has an App Store page. — [App Store SE: Kia Connect](https://apps.apple.com/se/app/kia-connect/id1577334573?l=en)
- The US uses different apps (Kia Access, formerly "Kia eServices"). — [App Store: Kia Access](https://apps.apple.com/app/id1280548773)

**EV features**
- The App Store description lists: remote climate, locks, windows, horn; EV charging management and a charging-station finder; Digital Key; real-time vehicle status; navigation with location sharing; service booking; Valet Mode; owner's manual; Driving Insights. — [App Store GB](https://apps.apple.com/gb/app/kia-app/id6740517042)
- Kia UK lists: battery status and time-to-full; **charging control from the Apple Watch**; EV Route Planner with chargers along the route; remote climate; remote unlock; Digital Key sharing with family and friends; driving insights (braking, acceleration, speed); "Entertainment Plus" upgrade (Netflix/YouTube); service booking; car sharing. Some features require the ccNC infotainment system, i.e. "from EV3 model onwards", so older EV6 (ccIC/Gen5W) cars get a subset. — [Kia UK: Kia App](https://www.kia.com/uk/electric-hybrid-cars/technology/kia-app/)
- Kia EU says the app can remotely start charging, monitor status and **schedule charging**, and control climate, hazard lights, horn and windows. — [Kia EU: Kia App](https://www.kia.com/eu/about-kia/experience-kia/technology/kia-app/) (via search snippet)
- I found no evidence of home-screen widgets, Live Activities or CarPlay-specific app features in the official listing text. Treat this as absence of evidence, not confirmation (see Gaps).

**Subscription terms (UK/EU)**
- Kia Connect is free for **7 years from first sale** to the first owner. After that, "connectivity features stop working unless you subscribe. You will be notified in advance." — [Kia Connect EU: Subscriptions](https://connect.kia.com/eu/product-information/ccs-subscriptions/)
- According to the Kia Connect FAQ search snippet, "Subscription availability starts in May 2026 and depends on model and market". After the trial, owners can buy "Kia Connect Premium" at prices that depend on the model. — [Kia Connect EU FAQ](https://connect.kia.com/eu/customer-support/faq/)
- Prices and package contents vary by model, model year, infotainment platform and country. They are shown only in the **Kia Connect Store inside the Kia App**, which displays only eligible packages. No public UK price list was found. — [Kia Connect EU: Subscriptions](https://connect.kia.com/eu/product-information/ccs-subscriptions/)

**Common complaints**
- App Store reviews criticise the redesign: "The screens are just too busy I have difficulty finding stuff". Switching between multiple vehicles is more complex than in the old app. Positive reviews praise remote functions, e.g. closing a window "from Zanzibar to here in UK". — [App Store GB](https://apps.apple.com/gb/app/kia-app/id6740517042)
- Forum thread "New Kia App is worse than last": the old app's elements were "reassembled awkwardly". Setting the charge-limit % is "buried" under the sprocket icon in the Control/EV tab. Owners also report zero battery or range display bugs and a UI that does not auto-size to the screen. — [kiaevforums.com](https://www.kiaevforums.com/threads/new-kia-app-is-worse-than-last.15007/) (search snippet only; the page is paywalled)
- SpeakEV "New Kia App" thread: users were logged out repeatedly. Kia reportedly fixed this later with a new identity provider. EV6 owners describe the app and software as "flaky", with the car forgetting off-peak charging settings. — [SpeakEV: New Kia App p.2](https://www.speakev.com/threads/new-kia-app.191243/page-2) (search snippet only)
- Remote climate from the app is described as "hit and miss". — [Kia Owners Club UK](https://www.kiaownersclub.co.uk/threads/climate-control-from-the-kia-connect-app.73724/); [kiaevforums: Kia Connect & Climate control](https://www.kiaevforums.com/threads/kia-connect-climate-control.717/) (search snippets)
- US owners also ask whether Kia Connect is becoming "increasingly laggy and slow". — [Facebook Kia EV Owners USA](https://www.facebook.com/groups/kiaevownersusa/posts/1036215737360742/) (title only)

**Hyundai Bluelink Europe (brief)**
- Android app `com.hyundai.bluelink.eu.ux20` is rated **about 1.8/5 from about 18k ratings** (AppBrain aggregate). The iOS Norway store shows 3.4/5 from 492 ratings. — [AppBrain](https://www.appbrain.com/app/hyundai-bluelink-europe/com.hyundai.bluelink.eu.ux20); [App Store NO](https://apps.apple.com/no/app/hyundai-bluelink-europe/id1565286187)
- EU terms: every new Hyundai gets **10 years of free Bluelink LITE plus a 6-month Bluelink PRO trial**. After that, owners choose PLUS or PRO in the Bluelink Store, or revert to LITE. — [Hyundai UK: Bluelink subscriptions](https://www.hyundai.com/uk/en/owners/owning-a-hyundai/discover-myhyundai-app/bluelink-subscriptions.html); [Hyundai EU](https://www.hyundai.com/eu/en/driving-hyundai/owning-a-hyundai/bluelink-connectivity/bluelink-subscriptions.html)
- The US MyHyundai app supports Apple Watch, including EV charge status and schedules. — [App Store US: MyHyundai](https://apps.apple.com/us/app/myhyundai-with-bluelink/id893514610)

### Inferences
- The 7-year free period (the fleet began in 2021/22) means paid Kia Connect only starts to bite for early EV6s around 2028–29. For current EV6 owners, the paid tier is not yet a pain point, but opaque in-app-only pricing could become one.
- The official app is broad (digital key, route planner, Watch) but weak on UX speed and discoverability. That leaves room for a focused, fast "EV6 remote" app with widgets and Live Activities, if it can get API access.
- The 4.1 iOS rating may be inflated by early prompts or reset by the new app ID. Forum sentiment is clearly more negative.

### Gaps
- Google Play rating, review count and installs for the EU Kia App: the page could not be fetched.
- Exact UK Kia Connect Premium prices: not published outside the app.
- Whether the Kia App offers iOS home-screen widgets, Live Activities or CarPlay integration: not stated in the sources found.
- Full forum threads could not be read because of the tollbit paywall. Complaint frequency is not quantified.

## Third-party apps and services (unofficial API vs official partner route)

### Takeaway
There is **no well-known, polished, App-Store-distributed third-party Kia remote-control app aimed at UK/EU** as of Sep 2026. The ecosystem is dominated by open-source libraries and Home Assistant:
- `kia_uvo` HA integration: 941 stars, about 6,000 opted-in installs.
- `hyundai_kia_connect_api` (Python): 368 stars.
- `bluelinky` (Node): 465 stars.

The one notable consumer iOS app, **BetterBlue**, is open source, in TestFlight beta, and has unclear EU support. Monitoring and logbook services (Tronity) and OBD-based apps (EVNotify) exist. Smartcar/Octopus car-side integrations for the Kia EV6 have historically been flaky or unavailable in the UK.

### Cited Findings
**Open-source libraries and Home Assistant (unofficial API)**
- **hyundai_kia_connect_api** (Python): 368 stars, 211 forks, 15 open issues, 1,870 commits, MIT. It covers the Kia UVO/Connect, Hyundai Bluelink and Genesis APIs in the EU, CA, US, CN, AU, IN, NZ and BR regions. "Primarily consumed by Home Assistant." EU login now uses RSA password encryption, OTP is supported where required, and EU trip info is supported. The maintainer no longer owns a Kia/Hyundai and is seeking maintainers. — [GitHub](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api)
- **EU login history**: in 2025 Kia EU broke password login, and users had to extract a 48-character refresh token and use it as the password. That workaround used scripts and a browser, and required release 2.44.1. Since v4.12.0, EU username/password login works again, and the library fetches refresh tokens itself. — [Discussion #1141](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/1141); [kia_uvo Discussion #1308](https://github.com/Hyundai-Kia-Connect/kia_uvo/discussions/1308); [Kia Europe Login Flow wiki](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/wiki/Kia-Europe-Login-Flow); [PR #1322 on wedged legacy logins](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/pull/1322)
- **kia_uvo** (Home Assistant custom integration, HACS): 941 stars, 201 forks, 1,210 commits, MIT, also seeking maintainers.
  - Regions: AU, EU, CA, CH, IN, NZ, BR, US (US, IN, CN and BR limited).
  - Controls: climate, charging, locks, windows, hazards, charge port, **charge limits**, V2L discharge, navigation, valet.
  - Monitoring: battery, range, doors, windows, tyres, odometer, service intervals.
  - Defaults: poll cached data every 30 min, force a fresh car poll every 4 h, and no forced refresh from 10pm to 6am. These defaults exist to protect the 12V battery and API quotas. — [GitHub kia_uvo](https://github.com/Hyundai-Kia-Connect/kia_uvo)
- **Home Assistant analytics**: `kia_uvo` had **6,034 installs** (top versions 3.15.0: 2,735; 3.16.0: 890; 3.13.0: 556). Analytics count only HA users who opted in, so real usage is higher. — [HA analytics custom_integrations.json](https://analytics.home-assistant.io/custom_integrations.json)
- **bluelinky** (Node.js): 465 stars, 116 forks, 29 open issues, MIT. Supports lock/unlock, remote start and climate, status, location, and EV charge targets. EU authentication uses "stamps". It warns that "frequent vehicle status refreshes may drain the 12V battery". — [GitHub bluelinky](https://github.com/Hacksore/bluelinky)
- ioBroker (a popular German home-automation platform) has Bluelink/Kia UVO adapters. — [ioBroker forum](https://forum.iobroker.net/post/1072244)

**Consumer apps**
- **BetterBlue** (iOS, by Mark Schmidt): native SwiftUI app. Features: lock/unlock, climate, charging, status; home-screen widgets; Apple Watch app; Siri Shortcuts; Live Activities for charging (beta, off by default). Supports EV, PHEV and ICE. Open source (MIT, 131 stars).
  - Distributed via TestFlight beta. The price and App Store listing were not found.
  - Requires an active Bluelink or Kia Connect subscription.
  - "Not affiliated with … Hyundai Motor Company or Kia Corporation". It uses the unofficial API.
  - Region support is not stated and appears US-centric (uncertain). — [markschmidt.io/betterblue](https://markschmidt.io/betterblue.html); [GitHub BetterBlue](https://github.com/schmidtwmark/BetterBlue)
- **TRONITY** (web, iOS and Android; German company): EV monitoring, driver's logbook and fleet platform.
  - Kia is supported for specific models only; compatibility is checked by VIN.
  - App pricing (search snippet): Premium €4.90/year, Professional €13.90/year, 14-day free trial.
  - Fleet: from €5/vehicle/month; integration or fleet admin €15/month on an annual plan.
  - Access route: likely an OEM or aggregator connection rather than the owner's Kia app login (unconfirmed). — [TRONITY help: supported manufacturers](https://help.tronity.io/hc/en-us/articles/24838180535836-Which-car-manufacturers-are-supported-by-TRONITY); [TRONITY app pricing](https://www.tronity.io/en/tronity-app/pricing); [App Store](https://apps.apple.com/us/app/tronity/id1549509183); [Google Play](https://play.google.com/store/apps/details?id=com.tronity&hl=en_US)
- **EVNotify** (Android; free and says it will stay free): originally built for the Ioniq Electric in Europe, which lacked Bluelink.
  - Supported cars: Ioniq Electric, Kona Electric, Soul EV, Niro EV and others.
  - Features: notifications when charging aborts, charge and consumption tracking, nearby chargers.
  - Requires a **Bluetooth OBD2 dongle left in the car**. This is an OBD route, not the cloud API.
  - Rated about 2.8/5 (AppBrain), with Bluetooth connection complaints. Aimed at older models; E-GMP EV6 support is unconfirmed. — [evnotify.de](https://evnotify.de/); [Google Play](https://play.google.com/store/apps/details?id=com.evnotify.app&hl=en_US); [AppBrain](https://www.appbrain.com/app/evnotify-the-app-for-your-el/com.evnotify.app)

**Official partner and aggregator route (Smartcar / Octopus)**
- A forum snippet (older, about 2022–23) says Smartcar supported many Kia models but the EV6 was only in "beta". — [kiaevforums: SmartCar API](https://www.kiaevforums.com/threads/smartcar-api.6502/)
- Octopus at one point stopped accepting Kia and Hyundai for Intelligent Octopus car-side integration. Reasons cited in the snippets: Smartcar-via-Kia-app connection problems and EV6 **12V battery drain**. — [Kia Owners Club UK](https://www.kiaownersclub.co.uk/threads/kia-has-been-removed-from-the-octopus-intelligent.73526/page-2); [SpeakEV](https://www.speakev.com/threads/intelligent-octopus-and-kia-ev6.178114/) (snippets, dated about 2022–23)
- As of a 2026 blog post, the Kia EV6, EV9 and e-Niro "currently have no car-side integration" with Intelligent Octopus Go. Kia owners must use a compatible charger (Ohme, Hypervolt, Zappi, Andersen, Indra, VCHRGD). — [EV Tariff (2026)](https://evtariff.co.uk/blog/intelligent-octopus-go-compatible-cars/). Octopus runs its own EV6 page. — [octopusev.com](https://octopusev.com/cars/kia-ev6)
- "EV Watch" and "Electrified" apps: I found no evidence that apps by these names support Kia/Hyundai. They may not exist under those names.

### Inferences
- The UK/EU gap is real. Technical users go to Home Assistant (thousands of installs). Non-technical owners have no polished third-party iOS app with widgets and Watch support that works in the EU. BetterBlue is the closest and is still beta and probably US-first.
- Every third-party remote-control option relies on the **unofficial** Kia/Hyundai cloud API, and has faced these risks:
  - login breakage (the EU refresh-token episode in 2025)
  - 12V drain from force-refreshes
  - maintainers stepping away (both core HA repos are looking for maintainers)
- Any new app must plan for auth churn, conservative polling, and possibly Kia's paid-subscription gating after 7 years.
- Smart-tariff integration for the EV6 in the UK is done through chargers, not the car. A car-API-based smart-charge planner is therefore a differentiator, but it carries reliability risk.

### Gaps
- No systematic App Store or Play search results for third-party "Kia EV6" or "Kia Connect" apps: the search tool does not index store search. There could be small niche apps that were not surfaced.
- No official Kia developer or partner API for consumers in the EU was found.
- Smartcar's current (2026) Kia EU coverage was not verified.
- BetterBlue's App Store price and EU support are unknown.
- Download counts for Tronity and EVNotify were not retrieved.

## Features users request that the official app lacks

### Takeaway
From the evidence available (mostly search snippets from paywalled forums plus App Store reviews), the main requests are:
- a faster, less cluttered UI with one-tap access to the charge limit
- reliable remote climate and command confirmation
- staying logged in
- easier switching between multiple cars
- persistent off-peak or charge schedules
- smart-tariff (Octopus) integration

Third-party projects add widgets, Live Activities, Siri Shortcuts, Watch and home-automation hooks, which signals demand for these.

### Cited Findings
- Charge limit is hard to reach ("buried" under the sprocket), and there are battery/range display bugs. — [kiaevforums](https://www.kiaevforums.com/threads/new-kia-app-is-worse-than-last.15007/) (snippet)
- Owners want to stay logged in (repeated logouts), and complain the car forgets off-peak charging settings. — [SpeakEV New Kia App](https://www.speakev.com/threads/new-kia-app.191243/page-2) (snippet)
- Owners want less busy screens and easier multi-vehicle switching. — [App Store GB reviews](https://apps.apple.com/gb/app/kia-app/id6740517042)
- Reliable remote climate is a recurring ask. — [Kia Owners Club UK](https://www.kiaownersclub.co.uk/threads/climate-control-from-the-kia-connect-app.73724/); [kiaev6forum](https://kiaev6forum.com/threads/problems-with-my-remote-climate-control.7/) (snippets)
- Intelligent Octopus car-side integration is repeatedly sought, and is currently unavailable. — [EV Tariff 2026](https://evtariff.co.uk/blog/intelligent-octopus-go-compatible-cars/); [kiaevforums: EV3 not in IOG list](https://www.kiaevforums.com/threads/ev3-not-in-the-intelligent-octopus-go-list.14870/)
- Third-party feature sets signal demand: BetterBlue ships widgets, Watch, Siri Shortcuts and charging Live Activities. — [GitHub BetterBlue](https://github.com/schmidtwmark/BetterBlue). kia_uvo exposes charge limits, V2L and automations. — [GitHub kia_uvo](https://github.com/Hyundai-Kia-Connect/kia_uvo)
- Recharged's 2026 guide reports broader EV6 software flakiness: failed infotainment updates, charging sessions that start and stop, and 12V failures. — [Recharged](https://recharged.com/articles/kia-ev6-common-problems-2026)

### Inferences
- Features a new app could win on for UK EV6 owners:
  - speed
  - home-screen and lock-screen widgets
  - Live Activities for climate and charging
  - a one-tap charge limit
  - schedules that survive
  - tariff-aware charging (Octopus Agile/Go) with cost tracking

  None of these are offered by the official app, per the sources found.
- Reddit r/KiaEV6 and r/Ioniq5 were not reached directly, so the request list is indicative rather than exhaustive.

### Gaps
- Reddit threads were not retrieved (no results surfaced). Complaints were not counted or ranked quantitatively.
- Full SpeakEV and kiaevforums threads were not readable (tollbit HTTP 402).
