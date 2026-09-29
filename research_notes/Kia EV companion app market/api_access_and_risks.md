# Kia/Hyundai connected-car API access routes (UK/Europe) and the risks of the unofficial Kia Connect API, as of Sept 2026

Research date: 2026-09-29. Tool-call budget limited coverage. Some items (Mobilisights, Caruso, Invers, 2hire, VW/Mercedes/GM precedents, bluelinky/US Kia history) could not be checked and are listed under Gaps.

## Q1. Official and partner routes: coverage, capabilities, pricing

### Takeaway
Kia/Hyundai have no self-serve public developer API for consumer apps in Europe. There are three sanctioned routes. (1) Aggregators: Smartcar, Enode and Tronity support Kia in Europe/UK, and some of them offer commands. (2) High Mobility, Kia's official data partner since Jan 2024, covers the EEA and UK, including the EV6, but is B2B, read-only as far as I found, and has a €99/month minimum. (3) Kia/Hyundai's new EU Data Act "Vehicle Data API" (Pleos platform), which appears to be read-only. For a small iOS app that needs remote climate or charge commands, Smartcar is the only option with a published self-serve price. Its command allowance is small (100 commands/month shared across all vehicles on the Build plan).

### Cited Findings
**Smartcar**
- Smartcar says it supports "all Kia models that support the Kia Connect app". The Kia landing page gives no model or signal list and no EV6 line. Per-signal support is in an interactive compatibility matrix that I could not render. — [Smartcar Kia](https://smartcar.com/brand/kia); [Smartcar compatibility](https://smartcar.com/product/compatible-vehicles)
- Smartcar announced Kia compatibility in Europe in June 2022 (older source). — [Smartcar blog, June 2022](https://smartcar.com/blog/june-2022)
- Smartcar's European coverage includes the United Kingdom. Its APIs cover EV battery level, charging status, start charge, lock/unlock "and more" (search summary of Smartcar pages). — [Smartcar global coverage](https://smartcar.com/global); [Smartcar Kia](https://smartcar.com/brand/kia)
- Smartcar pricing:
  - Free plan: 1 connected vehicle, 3 simulated vehicles, limited signals.
  - "Build" plan: from **$1.99 per vehicle per application per month**, up to 500 vehicles, **100 vehicle commands/month shared across all vehicles**, with Basic/Advanced/Premium signal tiers and possible overages.
  - Custom/Enterprise plan: **500 connected vehicles minimum**, tailored command volumes, SLAs.
  — [Smartcar pricing](https://smartcar.com/pricing)

**High Mobility (official Kia data partner)**
- Announced 23 Jan 2024. Kia partnered with High Mobility to give "third party software companies and fleet operators" access to data on the Sportage, Niro, Ceed, **EV6** and other models: confirmed mileage, vehicle location, consumption and charging information, vehicle health, tyre pressure and DTCs. Delivery is by MQTT/REST push and pull. The announcement mentions no remote commands. — [High Mobility blog](https://www.high-mobility.com/blog/kia-live-vehicle-data-now-available-via-high-mobility)
- High Mobility's Kia page / search summary: "live car data is provided in the European Economic Area (EEA) and United Kingdom." — [High Mobility Kia Data API](https://www.high-mobility.com/car-api/kia-data-api)
- Pricing is per active vehicle per month and depends on OEM data costs, data package and volume. There is a **€99/month minimum fee**, credited against vehicle charges and "usually consumed already after 20 active vehicles". No per-vehicle list price is published; there is a free sandbox. — [High Mobility pricing](https://www.high-mobility.com/pricing)

**Enode**
- Enode added Hyundai and Kia to its Connect API and targets energy/smart-charging use cases. Its public status page shows a "Kia & Hyundai: Elevated error rate" incident, which suggests Enode depends on the same backend and can be hit by the same outages. — [Enode blog](https://enode.com/blog/enode-increases-api-coverage-for-energy-innovators-in-the-usa); [Enode status](https://status.enode.com/incidents/01JBZ4X4RK1CCFDQAVGQX4D84Y)
- Enode publishes no prices; it asks for a sales contact for production access. — [Enode pricing](https://enode.com/pricing)
- ABRP uses Enode for Kia connectivity. Kia forum users report unreliable connections and ABRP refunds (anecdotal). — [Kia EV Forum: ABRP 5.0 and Enode](https://www.kiaevforums.com/threads/abrp-5-0-and-enode.11947/); [Kia EV Forum ABRP/EV9](https://www.kiaevforums.com/threads/connection-ev9-with-abrp.11232/page-2)

**Tronity**
- Tronity aggregates 20+ OEMs into a REST API: SoC, range, odometer, location, charging sessions and trips, "plus remote commands", with Kia (including the EV6) supported (search summary of apis.io listing). The platform charges **€15/month per integration or fleet administrator** (annual). It distinguishes "OEM managed" from "OEM un-managed" APIs, meaning some brands are accessed unofficially. — [apis.io Tronity](https://apis.io/providers/tronity/); [Tronity Platform pricing](https://www.platform.tronity.io/pricing?lang=en)
- Tronity's consumer app pricing was reported as €4.90 and €13.90 "per year". This looks implausibly low and may be per month, so verify it. — [Tronity app pricing](https://www.tronity.io/en/tronity-app/pricing)

**Kia/Hyundai's own EU Data Act channel**
- Hyundai Connected Mobility's Data Rights page says Kia provides a "Vehicle Data API … an open API for accessing vehicle data". A third party requests integration. After integration, the owner approves or rejects sharing in the third party's app and can revoke it in the Kia app (Privacy centre > My Vehicles > Partner services). Private users can request data at hcm.dataprotection@hyundai-europe.com. — [Hyundai Connected Mobility Data Rights](https://connected-mobility.hyundai.com/data-rights-en)
- Kia's Data Act information notice (Sept 2025) names **Kia Connect GmbH (Frankfurt)** as data holder, with Hyundai Motor Company and 42dot as technical parties. It lists endpoints such as Get Battery Charging Status, Powertrain Status, Location info and Vehicle status (JSON, ~10KB, "readily available, access per request"). For **CCS 2.0** vehicles these are updated "continuously and in real time", every 1 minute. For **CCS 1.0** vehicles they update only at "end of driving". Users can instruct sharing with a third party, and Kia then concludes "a separate data sharing agreement with such 3rd party". Kia may refuse on trade-secret grounds. — [Kia EU Data Act Information Notice (PDF)](https://www.kia.com/content/dam/kwcms/kme/pl/pl/assets/contents/EU_Data_Act_2025.pdf)
- Community analysis (Sept 2025): the new API offers "data sharing but not controlling the vehicle (start/stop)", with a preliminary reference on the Pleos platform. — [hyundai_kia_connect_api Discussion #887](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/887)

### Inferences
- The EV6 2022 is an early E-GMP car and is probably CCS 1.0 (ccNC is newer). If so, Data Act API data may update only at end of drive, not in real time. This is unverified; check which CCS generation the 2022 EV6 uses.
- Among official routes, only Smartcar and Tronity (and perhaps Enode for charging) appear to offer commands. Smartcar's 100 commands/month shared across the whole fleet is far too few for a precondition-focused app, so commands at scale would need an Enterprise contract with a 500-vehicle minimum.
- High Mobility and the Data Act API look suited to read-only features (SoC, odometer, location, charge history) at B2B pricing.

### Gaps
- No per-model/per-signal Smartcar matrix for the Kia EV6 in the UK (it is interactive). Unconfirmed whether Smartcar supports climate/precondition commands for Kia EU.
- No public Enode or High Mobility per-vehicle prices.
- Not researched: Mobilisights, Caruso, Invers, 2hire, and whether a "Hyundai Developers" portal serves EU consumer apps.
- Unclear whether the Kia Data Act API has fees for third parties, or whether it applies to UK vehicles (the data holder is a German entity and the notice is EU-law based).

## Q2. Unofficial API: breakage history, rate limits, lockouts, ToS, analogous OEM enforcement

### Takeaway
Kia/Hyundai's EU backend has broken the community libraries repeatedly:
- Aug 2024: daily limit introduced.
- Aug 2025: token format change.
- Sept 2025: Kia EU reCAPTCHA login.
- Oct 2025 to May 2026: Hyundai EU backend migration, which broke Hyundai logins for months.
- Aug 2026: some accounts affected again.

The Kia Connect EU Terms of Use explicitly prohibit sharing credentials with third-party apps and using them to connect third-party services to the Kia back-end. The wider industry shows OEMs will block unofficial access outright (BMW, Sept 2025) or replace it with paid APIs (Tesla, 2024 to 2026).

### Cited Findings
**Breakage timeline (hyundai_kia_connect_api / kia_uvo)**
- **8 Aug 2024**: users hit a new daily cap. The server message read: "The maximum number of daily vehicle checks has been exceeded. Please be aware that using 3rd party apps may contribute to exceeding this limit." — [kia_uvo #918](https://github.com/Hyundai-Kia-Connect/kia_uvo/issues/918)
- The EU limit is commonly cited as **~200 calls/day**, per the bluelinky wiki "API Rate Limits" (the page now returns 404; search summaries cite it). Earlier "Exceeds number of requests" errors are in kia_uvo #636. — [kia_uvo #636](https://github.com/Hyundai-Kia-Connect/kia_uvo/issues/636); [Speak EV thread](https://www.speakev.com/threads/kia-car-api-call-limit.181986/); the library README still links the rate-limit page: [hyundai_kia_connect_api README](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api)
- **7 Aug 2025**: EU login failed with KeyError 'token_type' because the auth response format changed. It was flagged as a repeat of #847. — [hyundai_kia_connect_api #855](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/issues/855)
- **By Sept 2025 (wiki edited 21 Sept 2025)**: the Kia EU login requires solving **Google reCAPTCHA**, "which cannot be automated with Python alone". Users had to log in once in a real browser and paste a refresh token as the password. — [Kia Europe Login Flow wiki](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/wiki/Kia-Europe-Login-Flow)
- **~13–15 Oct 2025**: Hyundai EU logins broke. Many EU accounts had moved to Hyundai's newer "MyHyundai" backend, while the integration targeted the old Bluelink EU API. Workarounds used Selenium scripts. The thread says direct username/password login was restored in **v4.12.0 (May 2026)**, and issues "resurfaced for some accounts" in **Aug 2026**. The summary also cites "v3.10.1+", probably the kia_uvo HA integration version; version numbers are uncertain. — [Discussion #921](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/921); [kia_uvo #1343](https://github.com/Hyundai-Kia-Connect/kia_uvo/issues/1343); [kia_uvo #1214](https://github.com/Hyundai-Kia-Connect/kia_uvo/issues/1214)
- The current README says "Username/password login is supported directly for Kia, Hyundai, and Genesis (EU) — no browser or manual token extraction needed", so the reCAPTCHA hurdle has been worked around for now. — [hyundai_kia_connect_api README](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api)
- An independent reverse-engineering write-up of the Bluelink/Kia Connect apps (May 2024) documents the techniques involved. — [kumo.dev blog](https://blog.kumo.dev/2024/05/22/reverse_engineering_hkg_apps.html)

**Kia Connect Terms of Use (Europe-English, effective July 2023; Kia Connect GmbH)** — [Kia Connect ToU PDF](https://connect.kia.com/content/dam/kia-uvo/global/assets/legal-docs/Kia%20Connect_Terms%20of%20Use_CC_Europe-English.pdf)
- §5.1: "You may not reproduce … modify, display, redeliver, license, link or otherwise use the Services for any public or commercial purpose without our prior permission."
- §5.2: the terms grant no licence to use any Kia "image, trademark, service mark or logo".
- §6.4.2: "You may only use your login credentials for the Services to log into the Kia Connect App and to connect the Head Unit to your Kia Connect App. You are not permitted to share your login credentials with any third party. It is in particular prohibited to use your login credentials to conne[ct any third-party service to Kia's systems, such as the] Kia Connect back-end." (The bracketed middle was garbled in PDF extraction; a search summary of the same terms gives that wording.)
- §6.4.4: "You must not connect the Kia Connect App to third-party applications in violation of its use."
- The same ToU confirm the official EV feature set: remote climate (including defrost), remote charge start/stop/schedule, remote door lock/unlock, heated/ventilated seats, windows, and hazard-light off ("EV6 only").
- A reverse-engineering prohibition ("reverse engineer, decompile, disassemble …") appears in Kia's US Kia Connect terms (search summary). — [Kia US Kia Connect Terms](https://va.kia.com/static/uvo-terms-of-use.html)

**Analogous OEM enforcement**
- **BMW, 29 Sept 2025**: BMW "blocked third parties (i.e. the BMW Connected Drive integration) from executing requests against BMW servers" through extra MyBMW app security checks. This hit HA "but also other companies such as energy providers". The community moved to BMW's official **CarData** API (EU-only for now). — [Home Assistant alert](https://alerts.home-assistant.io/alerts/bmw_connected_drive/); [bmw-cardata-ha](https://github.com/kvanbiesen/bmw-cardata-ha)
- **Tesla**: Tesla launched the Fleet API in Jan 2024 and is switching off the Owner API per account through 2025 into 2026. Paid pricing started Jan 2025: $1 per 50 wake requests, 150,000 streaming signals per $1, and a $10/month account credit. Tessie said it faced a ~$60M/year bill, and Teslascope said the fees were >7x its monthly revenue. — [Carscoops](https://www.carscoops.com/2024/11/tesla-api-costs-go-live-and-could-kill-many-apps-one-dev-says-he-faces-60m-bill/); [Not a Tesla App](https://www.notateslaapp.com/news/2415/tesla-announces-api-pricing-third-party-service-costs-expected-to-rise); [Big Iron guide](https://www.bigiron.cc/guides/tesla-fleet-api-costs-vs-owner-api-teslamate-survival); [Tesla Fleet API announcements](https://developer.tesla.com/docs/fleet-api/announcements)

### Inferences
- An app built on the unofficial API should expect roughly one significant EU auth/backend break a year, sometimes more, with outages from days up to about 7 months (the Hyundai case). Maintainers of an iOS port would have to follow the Python library's fixes closely.
- The ~200 calls/day cap is per account, and Kia's own error text blames third-party apps. Polling must be conservative, and heavy users could lock themselves out of the official app for the day.
- The ToU put the breach on the user, not the developer. The commercial-use clause (§5.1) and the trademark clause (§5.2) are the main exposure for a paid app. I found no documented cease-and-desist from Kia/Hyundai against a third-party app.

### Gaps
- No evidence found of Kia/Hyundai legal action, cease-and-desist, or account bans against users of third-party apps (not searched exhaustively).
- Could not verify the original bluelinky rate-limit page (404). The 200/day figure rests on secondary citations.
- Not researched: US Kia changes (bluelinky), VW WeConnect, Mercedes (HA case), GM/OnStar.
- Unclear whether the Europe ToU (Kia Connect GmbH) govern UK users, or whether a separate UK version exists (the connect.kia.com/uk accounts-terms page returned 404).

## Q3. App Store precedent for apps on unofficial car APIs

### Takeaway
Apple has cited Guideline 5.2.2 (third-party services require authorisation) and 5.2.1 (IP) against unofficial car-API apps. The best-known case: in Aug 2020 Apple demanded written consent from Tesla for "Watch app for Tesla", then let the update through while it reviewed the matter. Later developers report Apple asking for OEM authorisation documents. Enforcement looks inconsistent, but the risk is real, and a Kia-branded app name or icon increases it.

### Cited Findings
- Aug 2020: Apple rejected an update to "Watch app for Tesla" under **5.2.2**, requiring "written consent" from Tesla to use its unofficial API. Apple then let that update through while "investigating the matter further" and had not decided a permanent policy. — [9to5Mac](https://9to5mac.com/2020/08/27/apple-rejects-watch-for-tesla-app-as-it-starts-requiring-written-consent-for-third-party-api-use/); [Michael Tsai blog](https://mjtsai.com/blog/2020/08/28/app-rejected-for-using-unofficial-tesla-api/)
- Developers on Apple's forums report rejections under **5.2.1 Legal – Intellectual Property**, with Apple asking for "documentary evidence from Tesla" authorising vehicle control (search summary). — [Apple Developer Forums thread 717083](https://developer.apple.com/forums/thread/717083)
- Tesla later released official API documentation, ending the grey zone for Tesla apps. — [Slashdot](https://tech.slashdot.org/story/23/10/13/2047226/tesla-releases-official-api-documentation-to-support-third-party-apps)
- Kia's ToU §5.2 reserves all Kia trademark and logo rights. — [Kia Connect ToU PDF](https://connect.kia.com/content/dam/kia-uvo/global/assets/legal-docs/Kia%20Connect_Terms%20of%20Use_CC_Europe-English.pdf)
- Tronity's consumer app is live on the App Store and uses a mix of OEM-managed and "un-managed" APIs, which shows such aggregator apps are approved. — [TRONITY App Store](https://apps.apple.com/us/app/tronity/id1549509183); [Tronity Platform pricing](https://www.platform.tronity.io/pricing?lang=en)

### Inferences
- Using an official aggregator (Smartcar, High Mobility) gives a documented authorisation chain for App Review. Direct unofficial Kia API use could be challenged under 5.2.2 at any review, including on updates after initial approval.
- Naming the app with "for Kia"-style wording and avoiding Kia logos lowers 5.2.1 exposure, but does not remove 5.2.2 exposure.

### Gaps
- I did not identify specific current App Store apps that use the unofficial Kia/Hyundai API, or any rejection specific to Kia/Hyundai apps.

## Q4. EU Data Act and UK equivalents

### Takeaway
The EU Data Act (Reg. 2023/2854) has applied since 12 Sept 2025. It gives owners free access to "readily available" raw and pre-processed vehicle data (battery level, speed and similar), and the right to direct sharing to third parties. Third parties can be charged "reasonable compensation". Kia/Hyundai have implemented it through a partner "Vehicle Data API" with in-app consent, which appears to be read-only. The Commission's guidance treats remote functions as "related services", but I found no evidence the Act forces OEMs to expose remote commands to third parties. The UK is not covered. The UK's Data (Use and Access) Act 2025 only enables future "smart data" schemes, and no automotive scheme exists yet.

### Cited Findings
- The Data Act has applied since **12 Sept 2025**. The access-by-design obligation (Art. 3) applies to products placed on the market from **Sept 2026**. Contract-term rules follow in Sept 2027. — [Automotive IQ](https://www.automotive-iq.com/cybersecurity/how-to-guides/complying-with-the-eu-data-act-in-automotive); [Grape Up](https://grapeup.com/blog/eu-data-act-vehicle-guidance-2025-what-automotive-oems-must-share-by-september-2026)
- **Scope** (Commission guidance, 12 Sept 2025, summarised by Grape Up):
  - Covered: raw and pre-processed data, including "battery charge level", speed and DTCs. Manufacturers must share data they hold or "can lawfully obtain without disproportionate effort". Quality must equal what the OEM itself gets, "timeliness" included.
  - Access method is technology-neutral (backend, onboard or intermediary).
  - End-user access is free. B2B recipients can be charged "reasonable compensation" (Art. 9).
  — [EC guidance page](https://digital-strategy.ec.europa.eu/en/library/guidance-vehicle-data-accompanying-data-act); [Grape Up](https://grapeup.com/blog/eu-data-act-vehicle-guidance-2025-what-automotive-oems-must-share-by-september-2026)
- Derived or inferred data is out of scope. Related services "must involve bi-directional data exchange affecting vehicle functioning", for example remote locking/unlocking. — [Mayer Brown (Nov 2025)](https://www.mayerbrown.com/en/insights/publications/2025/11/the-eu-data-act-has-taken-effect-focus-on-automotive-and-cloud-providers)
- Kia's implementation: the Data Act notice (Kia Connect GmbH) and the Hyundai CM Data Rights page (Vehicle Data API, third-party integration, consent and revocation in the app). Community reading: data only, no vehicle control. — [Kia Data Act notice](https://www.kia.com/content/dam/kwcms/kme/pl/pl/assets/contents/EU_Data_Act_2025.pdf); [HCM Data Rights](https://connected-mobility.hyundai.com/data-rights-en); [Discussion #887](https://github.com/Hyundai-Kia-Connect/hyundai_kia_connect_api/discussions/887)
- **UK**: the Data (Use and Access) Act 2025 received Royal Assent on **19 June 2025**. It gives government powers to create mandatory "smart data schemes". Transport is one of 10 target sectors. Commentary gives a hypothetical in which a connected-vehicle maker could be required to share usage records with an authorised third party. The Smart Data 2035 strategy targets 5+ schemes by 2030. — [UK Parliament bill page](https://bills.parliament.uk/bills/3825); [Browne Jacobson](https://www.brownejacobson.com/insights/duaa-2025-on-uk-manufacturing-industrial-and-automotive-sectors); [CMS](https://cms.law/en/gbr/legal-updates/smart-data-schemes-enhanced-data-sharing-in-the-uk-under-the-new-data-use-and-access-act); [NatLawReview](https://natlawreview.com/article/uk-smart-data-and-data-use-and-access-act-2025-considerations-businesses)

### Inferences
- A UK-registered EV6 owner probably has no Data Act rights, since the Act is EU law and applies to products placed on the EU market or to users in the EU. Kia might still extend the partner API to UK cars voluntarily. This is unverified.
- Even in the EU, the Data Act route supports read-only features, not remote preconditioning. It could lower cost and legal risk for telemetry features only.

### Gaps
- Could not confirm whether the Kia Vehicle Data API is available to UK accounts, what it costs third parties, or how onboarding works (Pleos docs not reviewed).
- No UK automotive smart-data scheme found as of Sept 2026.
- The Commission's model contractual terms and compensation guidance were not reviewed.
