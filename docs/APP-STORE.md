# App Store submission pack

Everything to paste into App Store Connect, and what's still to decide.

## Before submitting

- [ ] **Name.** Placeholder "Volt Lab" (in `AppInfo.name` and `project.yml`). Check it's free on the App
      Store and has no trademark clash. The App Store Connect record is still called "My EV6": rename it.
      If the name changes, also change "Volt Lab Pro" and "Unlock Volt Lab Pro" in the review notes below.
- [ ] **Pro in-app purchase.** Create a non-consumable with the ID `com.luciusgee.ev6precondition.pro`
      (suggested £9.99 / $9.99 tier, Family Sharing on), add a review screenshot of the Pro sheet, then set
      `Store.paywallEnabled = true` in `EV6Precondition/Platform/Store.swift`. Until then everything is free.
- [ ] **Attach the IAP to the version** (only with the paywall on). A first in-app purchase is reviewed with an app version: on the
      version page, add the Pro IAP under In-App Purchases before submitting, or it won't be reviewed.
- [ ] **Pro markers.** With the paywall on, keep the "(Pro)" tags and the Free/Pro line in the description
      below (Guideline 2.3.2). If the paywall stays off for this version, remove them, delete the
      "In-app purchase:" paragraph from the review notes (the Unlock row, locks and Restore button are
      hidden), and don't create, attach or submit the IAP yet: skip the two IAP items above.
- [ ] **Support URL and privacy policy URL.** Both are required. The privacy text in the app
      (More › Privacy, `AboutText.privacy`) can be published as-is, e.g. as a GitHub Pages page.
- [ ] **Screenshots** (6.9" and 6.5" iPhone): Car tab with the live chassis, a 0–60 result card,
      the battery report, the module map, trouble codes, a charge curve. The demo car produces all of them
      except the charge curve: the demo can't charge, so take that one on a real car at a charger.
- [ ] **Lap timer recording.** Record 20–30 s of the lap timer on a circuit (arming the line, a lap
  completing) and attach it in App Store Connect's review notes: the demo car can't drive it.
- [ ] **Charging recording.** Record 20–30 s of More › Charging during a real charge (the live power curve
  building) and Charge history with a saved session, and attach it with the lap timer recording: the demo
  car can't charge.
- [ ] Age rating questionnaire: no objectionable content → 4+.
- [ ] Export compliance: no non-exempt encryption (already set in Info.plist).

## Listing

**Subtitle** (30): `EV battery health, OBD scanner`

**Promotional text** (170):
Battery health with every cell, 0–60 and quarter-mile timing, charge curves and trouble codes, straight from your car's OBD port. Nothing leaves your phone.

**Description:**

Plug a Bluetooth OBD adapter into your car and see what it knows.

BATTERY HEALTH (E-GMP cars)
• State of health, every cell's voltage, the weakest and strongest cells, and a map of every module
• Usable capacity, cycles since new, temperatures and balance, each with a plain-English verdict
• A spec-sheet PDF report to keep, or to give a buyer when you sell (Pro)

PERFORMANCE
• 0–60 mph, 0–100 km/h, 0–100 mph, 0–200 km/h
• ⅛, ¼ and ½ mile, standing kilometre and mile, with trap speed and splits
• 30–70, 50–70 mph, 80–120 and 100–200 km/h in-gear times, and 60–0 / 100–0 braking
• Optional 1 ft rollout, launch detection with the phone's motion sensor, speed and power charts
• GPS lap timer with a live delta to your best lap (Pro)

CHARGING (E-GMP cars)
• Record a charge with the app open: the power curve against charge, energy added, 10–80% time and battery temperature
• Charge history: every past charge's curve, energy and temperatures (Pro)

DIAGNOSTICS
• Read and clear trouble codes from every module, with explanations
• Live data and graphs for every sensor, data recording to CSV (Pro), module identifiers and VIN, trip computer

CARS
Deep battery and vehicle data for E-GMP cars: Kia EV6 and EV9, Hyundai Ioniq 5, Ioniq 5 N, Ioniq 6 and Ioniq 9, Genesis GV60 and Electrified GV70, detected automatically. Speed, engine data, emission codes and performance timing on almost any other car with standard OBD-II.

ADAPTERS
Bluetooth LE or Wi-Fi ELM327 adapters such as Veepeak OBDCheck BLE, OBDLink CX and vLinker MC+. Classic Bluetooth adapters can't connect to iPhone.

PRIVATE
No account, no tracking, no adverts. Everything stays on your iPhone.

FREE AND PRO
Free: live data, trouble codes, battery check, performance timing, live charge recording. Pro, a one-off in-app purchase: battery PDF report, lap timer, charge history, data recording.

Performance timing is for closed roads and tracks only. Readings are estimates from the car's OBD data, not a manufacturer's diagnosis. Not affiliated with Kia, Hyundai, Genesis or any car maker.

**Keywords** (100): `obd2,obd,ev,battery,health,soh,scanner,elm327,0-60,quarter mile,charge,diagnostic,codes,lap timer`

**Category:** Utilities (secondary: Productivity or Sports). Keep car model names out of the keywords
(trademarks, Guideline 2.3.7): they belong only in the description's CARS paragraph.

## App Review notes

> The app talks to a car through a Bluetooth OBD-II adapter, which reviewers won't have. To see every
> feature without one, open the app and tap **Try the demo car first** on the last onboarding page (or
> More › Use the demo car). It simulates a Kia EV6: the Car tab shows live data, Battery › Read battery
> produces a full report and PDF, and on Performance pick 0–60 mph and tap **Arm**: the simulated car
> launches by itself two seconds later. Braking runs work the same way. Codes › Scan All Modules finds
> two sample codes.
>
> The lap timer (Performance) needs real GPS movement around a circuit, so the demo car can't drive it:
> a short screen recording of it in use is attached in App Store Connect.
>
> Charging (More › Charging, and Charge history) records only while a real car is plugged in and
> charging, so the demo car can't show it either: a short screen recording of a real charge is attached
> as well.
>
> Bluetooth is used only for the adapter; location only by the lap timer while a session is set up or
> running; motion only to
> detect the launch in a timed run. No data leaves the device.
>
> In-app purchase: one non-consumable, `com.luciusgee.ev6precondition.pro` (Volt Lab Pro), which unlocks
> the battery PDF report, lap timer, charge history and data recording. The Pro sheet opens from
> More › **Unlock Volt Lab Pro**, or by tapping any locked feature (for example **PDF report** on the battery
> report with the demo car). **Restore purchase** is on the Pro sheet and under More › About.

## Privacy nutrition label

Data Not Collected. (`EV6Precondition/PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1) and system
boot time (35F9.1, timing runs) and no tracking.)

## Pricing (recommended)

Free download with a one-off **Pro** unlock at **£9.99 / $9.99**. Free: live data, trouble codes, battery
check, performance timing, live charge recording. Pro: battery PDF report, lap timer, charge history, data recording.
For comparison, EV Dashboard (E-GMP) is $12.99 one-off, Car Scanner Pro $7.99 lifetime, LeafSpy Pro ~$20.

## Adding cars later

Public, reusable PID sources: OVMS (MIT, about 45 cars; credit it in Acknowledgements) and ABRP's
ev-obd-pids (Apache-2.0; check each folder's origin). Avoid copying from OBDb (CC BY-SA), WiCAN (GPL) or
unlicensed collections. Next most worthwhile: Nissan Leaf, then VW MEB (ID.3/ID.4/Enyaq/Q4), then the
first-generation Kona/e-Niro.
