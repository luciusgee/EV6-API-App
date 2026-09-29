# OBD diagnostic apps and smart-charging / tariff integrations for Kia/Hyundai E-GMP EVs (UK/Europe, 2026)

Research date: 2026-09-29. About 20 search/fetch calls. Forum pages on speakev.com and kiaownersclub.co.uk redirect to a paywalled "tollbit" host and could not be fetched in full, so claims from them come from search snippets only (flagged below).

## (a) OBD diagnostic apps and battery-health (SOH) services used by EV6 / Ioniq 5/6 owners

### Takeaway
Among E-GMP owners, **Car Scanner ELM OBD2** is the leading OBD app. It is cheap (a one-off purchase of about £8 unlocks Pro), highly rated (4.8 stars on iOS UK) and shows SOH, cell voltages, temperatures and DTCs through an E-GMP profile. Owners also use **ABRP** for live SoC over OBD and a small number of Hyundai/Kia-specific tools (Soul EV Spy, EVNotify, EVOBD2). For resale-grade proof, the UK route is a paid third-party certificate, mainly **Aviloo** (£100 TÜV-certified test, which now comes with a battery purchase guarantee). No OBD app ties into remote control or tariffs.

### Cited Findings
**Car Scanner ELM OBD2 (iOS + Android, developer Stanislav Svistunov)**
- UK App Store: 4.8/5 from about 9,800 ratings. Pro IAPs: £7.99 "forever", £4.49 per year, £3.49 per 6 months, plus a £6.99 tier. The listing page showed version 2.1.46 dated 29 June 2024. That date may be stale in the scrape, so re-check it. [App Store UK](https://apps.apple.com/gb/app/car-scanner-elm-obd2/id1259933623)
- US pricing is $7.99 lifetime, $4.99 per year and $3.99 per 6 months. The free tier includes diagnostics, live data, coding, EV/hybrid support and HUD. [OBDadvisor review 2026](https://obdadvisor.com/car-scanner-elm-obd2-review/); [Car Scanner FAQ](https://www.carscanner.info/faq/)
- Has manufacturer-specific profiles for Hyundai/Kia E-GMP (Ioniq 5, EV6). The profile must be selected in settings to reach BMS PIDs such as SOH, cell voltages, temperatures, SOC and cell deltas. [OBDadvisor EV scanners 2026](https://obdadvisor.com/obd2-scanner-electric-car/); [Autodoc UK guide](https://www.autodoc.co.uk/info/best-apps-and-obd2-tools-to-check-ev-battery-health-complete-uk-guide)
- An EV6 GT owner reported about 3.8 V cells with no differential and BMS SOH of 100% at 36.5k miles. [Kia EV Forum – OBD scanner](https://www.kiaevforums.com/threads/obd-scanner.13320/) (search snippet)
- Hardware caveat: cheap "ELM327 v2.1" clones (£5–10) overflow on EV CAN traffic. Owners recommend OBDLink CX/MX+ or Vgate iCar Pro. [OBDadvisor](https://obdadvisor.com/obd2-scanner-electric-car/)
- A 2026 VoltChek guide lists Car Scanner as Free / $9.99 Pro with E-GMP support covering SoH, pack voltage, cell data and DTCs. That price conflicts with the store listing above, so treat the store as authoritative. [VoltChek blog, 16 Mar 2026](https://voltchek.app/blog/ev-battery-health-check-app-guide)

**ABRP (A Better Routeplanner) with OBD live data**
- Links an OBD dongle to ABRP so live SoC and consumption feed the route plan. The EV6 OBD port is in the fuse panel. [EV Tips](https://ev-tips.com/abrp-obd2-bluetooth-linked-for-live-data/)
- Forum reports say ABRP Premium is no longer needed for the OBD live-data link, and the OBDLink CX works well on the EV6. [Kia EV Forum](https://www.kiaevforums.com/threads/obdc-required-for-abrp-live-data-for-ev9.12514/) (snippet). I did not find the current ABRP Premium price.
- UK owners discuss pairing ABRP with CarPlay/AA "AI boxes" and OBD adapters because the Kia's own data is limited. [Kia Owners Club](https://www.kiaownersclub.co.uk/threads/abrp-preconditioning-carplay-aa-ai-boxes-and-obd-adapters.71762/); [Speak EV](https://www.speakev.com/threads/abrp-carplay-aa-ai-boxes-and-obd-dongles.177128/) (snippets)

**Hyundai/Kia-specific OBD apps**
- **Soul EV Spy** (Android, by "evranger") shows SOH, BMS cell voltages and module temperatures for Ioniq 5, Ioniq 6, EV6, EV9, e-Soul, e-Niro and Kona EV. It is designed around the Vgate iCar Pro adapter. [Google Play](https://play.google.com/store/apps/details?id=com.evranger.soulspy&hl=en_US&gl=US) (snippet; the listing fetch failed, so rating and price are unknown)
- **EVNotify** is free and open source (Android). It monitors SoC remotely and sends push, email or Telegram alerts at a target SoC. It was built for the Ioniq Electric and supports Kona, Niro and Soul. Native Ioniq 5/EV6 support is reported as limited. [GitHub](https://github.com/EVNotify/EVNotify); [Google Play](https://play.google.com/store/apps/details?id=com.evnotify.app&hl=en_US); [Ioniq Forum](https://www.ioniqforum.com/threads/ioniq-5-android-auto-odb2-car-scanner-app-or-evnotify-app-abrp-premium.37170/)
- **EVOBD2** is a dedicated Bluetooth mini display for Hyundai/Kia EVs. It shows SoC, battery temperature, SOH, cabin temperature, 12V aux state and cumulative charged/discharged energy. [evobd2.com](https://evobd2.com/) (price not captured)
- **EV Watchdog** (Android) is an OBD reader, originally for the Soul EV. [MyKiaSoulEV forum](https://www.mykiasoulev.com/threads/ev-watchdog-app.1676/)
- I found no reliable sources for apps named **"EV Doctor"**, **"EVBatMon"** or **"OBD Car Doctor"** in relation to E-GMP. I also did not verify Torque Pro E-GMP PID packs.

**SOH certificate services (UK)**
- **Aviloo**: a TÜV-certified battery certificate from a roughly 3-minute "Flash Test" that covers about 96% of EV models on European roads. It shows SoH and a cell-level view of the pack. The £100 test is paid to an approved UK tester. Dealers pay £35 per test through MotorCheck. [aviloo.com](https://aviloo.com/en/); [MotorCheck × Aviloo](https://aviloopartner.motorcheck.org/motorcheck/); [AVILOO Private](https://aviloo.com/en/aviloo-private)
- Aviloo publishes a sample certificate for a Kia EV6 AWD 77.4 kWh (Feb 2023): SoH above 100%, 490 km range. [PDF](https://assets.ctfassets.net/jyl3c0cp0pqs/bRwqWj1FSbEwN0ETUM563/20e6f36d101ec22d88bed24afd9ddebf/AVILOO-Certificate-Kia-EV6_AWD__-_77_4_kWh-KNAC481CPN5044628-2023-02-21.pdf)
- A 2026 purchase guarantee gives one year / 20,000 km of cover against the SoH falling below a vehicle-specific limit. It launched in July 2026 in DE, UK, CH, FI, NL, AT, BE and IE. [electrive, 16 Jun 2026](https://www.electrive.com/2026/06/16/e3000-for-battery-defects-aviloo-converts-battery-diagnostics-into-a-purchase-guarantee/); [AM Online](https://www.am-online.com/news/aviloo-launches-battery-warranty-for-used-ev-buyers-in-uk)
  - **The payout figure conflicts between sources.** Aviloo's site says "£2,700 AVILOO Battery Warranty" (search snippet). electrive's headline says €3,000, and its body text says "£3,000 compensation plus refund of test costs".
- Aviloo updated its certificate to add cell-level diagnostics, benchmarking and range insights. [Charged EVs](https://chargedevs.com/newswire/aviloo-updates-its-ev-battery-certificate-with-cell-level-diagnostics-benchmarking-and-range-insights/)
- Other UK certificate providers exist, e.g. batteryhealthcheck.co.uk ("EV Battery Health Check & Certificate"). [batteryhealthcheck.co.uk](https://www.batteryhealthcheck.co.uk/) (not fetched, so price and method are unverified)
- Free web "estimate" tools such as VoltChek (no OBD) also target Ioniq 5/EV6 owners. [VoltChek Ioniq5/EV6 guide](https://voltchek.app/blog/hyundai-ioniq5-kia-ev6-battery-health)

### Inferences
- OBD tools are a price-commoditised market (£0–8 one-off). Owners pay for accuracy and E-GMP-specific decoding, not for subscriptions.
- The E-GMP OBD apps are either generic (Car Scanner) or niche and Android-only (Soul EV Spy, EVNotify). None combine OBD SOH history with Kia Connect remote functions or charging cost. An iOS app that logs SOH and cell deltas over time looks under-served.
- Paid certificates (Aviloo) serve a different moment: selling or buying used. A companion app could feed into that moment, e.g. through an exportable SOH history, but cannot replace a TÜV certificate.

### Gaps
- Ratings, price and last-update date for Soul EV Spy, EVNotify and EVOBD2 were not captured.
- No sources found for "EV Doctor", "EVBatMon" or "OBD Car Doctor" on E-GMP.
- Generational's UK SOH service was not researched.
- Current ABRP Premium price was not found.
- Whether Car Scanner is still actively updated in 2026 is unconfirmed (the scraped version date was 2024).

## (b) Smart charging / tariff / charger integrations that work with Kia EVs (UK/Europe)

### Takeaway
As of mid/late 2026, Kia/Hyundai E-GMP cars have **no working car-side (API) integration with Intelligent Octopus Go**. Octopus removed Kia/Hyundai from its vehicle list, reportedly because frequent polling drained the 12V battery. EV6 owners get IOG only through a compatible charger (Ohme, Zappi, Hypervolt, Andersen, Indra, etc.). OVO Charge Anytime supports Kia through the car, via Enode, but users call that path "extremely unreliable" and it also recommends a charger. The big 2026 change is **Hyundai Motor Group's Kaluza partnership (Aug 2026)**: smart charging is being built into the Kia App itself, launching with OVO in the UK in autumn 2026, under the "AllDayEnergy" umbrella with V2G from 2027.

### Cited Findings
**Intelligent Octopus Go (IOG)**
- "Hyundai (Ioniq 5/6, Kona Electric), Kia (EV6, EV9, e-Niro)… currently have no car-side integration". The reason given is that HMG's Bluelink service "has not opened the API surface required for third-party schedule control." Owners must use a compatible charger. [EV Tariff, updated 26 Jul 2026](https://evtariff.co.uk/blog/intelligent-octopus-go-compatible-cars/)
- Compatible chargers listed there include Ohme Home Pro/ePod, Hypervolt Home 3 Pro, Zappi V1, Andersen A3/Quartz, Indra Smart Pro/Lux and VCHRGD Seven/Pro. The same page says to confirm with Octopus's live checker. [EV Tariff](https://evtariff.co.uk/blog/intelligent-octopus-go-compatible-cars/)
- History: Kia EVs were added to IOG car integration at one point. [Kia Owners Club – "Intelligent Octopus now available for Kia EVs"](https://www.kiaownersclub.co.uk/threads/intelligent-octopus-now-available-for-kia-evs.71891/) (title only; paywalled). They were later removed. Owners reported around "August 21st" that the EV6 would no longer schedule. Owners attribute the removal to HMG's weak 12V maintenance: IOG polling wakes the car and can flatten the 12V. Affected customers were pointed to Octopus Go or an Ohme/Zappi charger. [Kia Owners Club – "Kia has been removed…"](https://www.kiaownersclub.co.uk/threads/kia-has-been-removed-from-the-octopus-intelligent.73526/); [Speak EV – "Octopus removed my car"](https://www.speakev.com/threads/octopus-removed-my-car-kia-now-not-on-their-list.184585/) (search snippets; the year of removal is unclear, likely 2025)
- Using a charger instead of the car API also avoids 12V drain from polling. [EV Tariff](https://evtariff.co.uk/blog/intelligent-octopus-go-compatible-cars/)
- A YouTube video shows an EV6 on IOG via a Zappi. [YouTube](https://www.youtube.com/watch?v=LvzbXchgapI)
- Continuing Kia app/IOG problem threads: [Kia Owners Club](https://www.kiaownersclub.co.uk/threads/intelligent-octopus-and-kia-app-problems-again.76441/); [Speak EV](https://www.speakev.com/threads/kia-ev6-and-intelligent-octopus-does-it-work.179774/) (snippets)

**Ohme**
- IOG is set up in the Octopus app by signing in to the Ohme account. Ohme warns against pairing both the car and the charger, because conflicting schedules cause failed sessions. [Ohme support](https://ohme-ev.com/support/troubleshooting-for-intelligent-octopus-go-and-ohme/)
- Ohme Home Pro supports Octopus Go, Agile and Cosy. On Agile it imports half-hourly rates and schedules the cheapest slots. [EV Tariff Ohme review 2026](https://evtariff.co.uk/chargers/smart/ohme-home-pro-review/)
- Agile workflows are also common in Home Assistant (e.g. the BottlecapDave Octopus integration with Ohme; the myenergi Python client). [GitHub issue](https://github.com/BottlecapDave/HomeAssistant-OctopusEnergy/issues/573); [ashleypittman/mec](https://github.com/ashleypittman/mec)

**OVO Charge Anytime**
- Two routes: a compatible charger (recommended) or the vehicle API via Enode. Only one is needed. For Kia, "the Kia integration has proven to be extremely unreliable for reasons beyond OVO's control", with Bluelink blamed. [OVO Forum – Charge Anytime with Kia](https://forum.ovoenergy.com/electric-vehicles-166/charge-anytime-with-kia-19500)
- A Kia Owners Club thread says "Ovo Charge Anytime Now Supporting Kia/Hyundais". [Kia Owners Club](https://www.kiaownersclub.co.uk/threads/ovo-charge-anytime-now-supporting-kia-hyundais.76398/) (title only)
- Rate: 14p/kWh as of Nov 2025, down from 7p historically. It is applied as a bill credit in arrears. [OVO](https://www.ovoenergy.com/electric-cars/charge-anytime); [teslacharger.co.uk](https://teslacharger.co.uk/tariffs/ovo-charge-anytime/)

**Kaluza × Hyundai Motor Group (new, Aug 2026)**
- HMG picked Kaluza as its global smart-charging partner, starting with Kia and Hyundai in the UK and then Australia. The feature is built into the Kia App and myHyundai App. OVO is the first supplier. Kia drivers on the OVO Charge app move to the Kia App "by early autumn" 2026, and Hyundai follows shortly after. V2G is planned from 2027. [electrive, 27 Aug 2026](https://www.electrive.com/2026/08/27/hyundai-group-integrates-smart-charging-control-from-kaluza/); [Kaluza press release](https://www.kaluza.com/press-releases/kaluza-hyundai-motor-group-global-ev-charging-partnership); [The Driven](https://thedriven.io/2026/08/27/hyundai-selects-partner-to-power-ev-smart-charging-and-prepare-for-imminent-rollout-of-v2g/)
- HMG groups smart charging, V2G and V2H under a new "AllDayEnergy" brand (announced July 2026). [electrive, 27 Jul 2026](https://www.electrive.com/2026/07/27/hyundai-and-kia-consolidate-smart-and-bidirectional-charging-under-new-brand/)
- Which models are covered (e.g. whether the 2021–23 EV6 on the old Kia Connect stack is included) is not stated. [electrive](https://www.electrive.com/2026/08/27/hyundai-group-integrates-smart-charging-control-from-kaluza/)

**Europe: Tibber, Enode, Jedlix**
- Tibber (DE) sells "Kia Smart Charging", which charges the Kia automatically in the cheapest hours when combined with a smart meter. [Tibber DE](https://tibber.com/de/store/produkt/kia-laden)
- Enode is the API layer many suppliers use for car-side connections (30+ brands, 900 models). [Enode](https://enode.com/use-cases/electric-vehicles). Enode also powers charger integrations, e.g. Peblar, for suppliers such as Tibber. [Peblar blog](https://peblar.com/blog/enode-energy-app-integration)
- Jedlix offers a smart-charging API and OEM programmes. Kia-specific support was not confirmed. [Jedlix](https://www.jedlix.com/car-manufactures)
- Hobbyist bridges such as EVConduit pipe Enode data into Home Assistant, ABRP and Tibber. [evconduit.com](https://evconduit.com/)

### Inferences
- Third-party car-side control of Kia charging is structurally unreliable (Bluelink API limits and 12V drain). The charger is the de facto integration point in the UK. An independent app using the Kia API for tariff-aware scheduling would hit the same 12V and polling problems. It should poll sparingly and prefer charge-limit/schedule commands over frequent status wakes.
- Kaluza/OVO inside the Kia App will reduce the gap for OVO customers, but it locks Kia owners to one supplier at launch. Octopus IOG/Agile customers without a smart charger remain under-served, which is a clear niche for Agile-aware scheduling.

### Gaps
- Octopus's official IOG compatibility page was not fetched, so the current Kia status is sourced from EV Tariff and forums.
- The exact date of Kia's removal from IOG is unconfirmed.
- Pricing for Pod Point, Hypervolt, Andersen and Zappi hardware, and whether each supports Agile, was not researched.
- Optiwatt UK, Axle Energy and EDF EV tariffs were not covered; no results tied them to Kia.
- Whether the Kaluza/Kia App feature supports older EV6s is unknown.

## (c) Cost/efficiency tracking apps, and the gaps owners want filled

### Takeaway
Public-charging apps (Zapmap, Octopus Electroverse) handle payment and discovery, not whole-life cost tracking. Zapmap Premium costs £29.99/yr or £3.49/month for a 5% discount and extras. Home-charging cost tracking lives in the charger's app (Ohme, myenergi), the supplier's app or Home Assistant setups. No single app combines Kia remote control, OBD battery health and tariff-aware charging and cost tracking.

### Cited Findings
- Zapmap plans: Free (£0; £10 charging card; 1 vehicle; 3 saved routes). Premium Annual £29.99/yr (about £2.49/month) or Monthly £3.49, which adds a 5% discount on Zapmap-paid sessions up to 50 kWh/month, a free card, unlimited vehicles and routes, CarPlay/Android Auto and no ads. [Zapmap plans](https://www.zapmap.com/app/plans-compared)
  - A third-party page quotes Premium at £2.99/month, which conflicts with the above. Use the Zapmap page. [evchargingcards.net](https://evchargingcards.net/cards/zapmap-zap-pay)
- Octopus Electroverse is free with a free RFID card. It covers 950+ networks and 500k+ points across the UK/EU, with route planning and "Plunge Pricing" events. [evchargingcards.net comparison](https://evchargingcards.net/compare/electroverse-vs-zapmap)
- OVO shows Charge Anytime credits in arrears in its app's energy hub, so the EV share of the bill is not visible live. [OVO Forum](https://forum.ovoenergy.com/electric-vehicles-166/charge-anytime-with-kia-19500)
- Owners combine multiple tools, e.g. Car Scanner or EVNotify with ABRP Premium on the Ioniq 5, which shows fragmentation. [Ioniq Forum](https://www.ioniqforum.com/threads/ioniq-5-android-auto-odb2-car-scanner-app-or-evnotify-app-abrp-premium.37170/)
- Integrators (Home Assistant + Octopus/Ohme/myenergi, EVConduit) show that power users build their own cost-aware stacks. [BottlecapDave HA issue](https://github.com/BottlecapDave/HomeAssistant-OctopusEnergy/issues/573); [EVConduit](https://evconduit.com/)

### Inferences
- Gaps a Kia-focused companion app could fill:
  1. Agile/Go-aware charge planning for owners without an IOG-compatible charger, using the car's schedule and charge limit sparingly to protect the 12V.
  2. Unified home and public cost ledger (pence per mile).
  3. SOH trend history from OBD, which no current iOS app provides specifically for E-GMP.
  4. All of the above in one app with Kia Connect remote functions, since the official Kia App lacks OBD depth and Octopus tariff awareness.
- The Kaluza/OVO integration arriving in the Kia App (autumn 2026) is the main incumbent threat for OVO customers only.

### Gaps
- EV-specific cost-tracker apps (e.g. "EV Charge Tracker"), their pricing and their ratings were not researched in this pass.
- No survey data found quantifying how many owners want a combined remote + OBD + tariff app. That gap is inferred from forum fragmentation.
- Spreadsheet workflows were not sourced.
