# Notes for Claude

- Work on and push to `main` directly. Don't create feature branches or pull requests unless asked.
- To ship to TestFlight: `git push origin main:release` (Codemagic's ios-testflight runs on pushes to `release`). Build results show as GitHub check runs on the commit.
- With `CODEMAGIC_API_TOKEN` set, `scripts/codemagic.sh start|status|cancel` drives Codemagic directly (e.g. `start ios-testflight main` rebuilds without a push). Never commit the token.
- Core logic lives in `PreconditionKit/` and must stay free of UIKit/SwiftUI so it builds and tests on Linux: `swift test --package-path PreconditionKit`.
- The iOS app (`EV6Precondition/`) is built by Codemagic (`codemagic.yaml`); the Xcode project is generated from `project.yml` by XcodeGen and isn't committed.
- HANDOVER.md, FUNCTIONS.md and TESTS.md describe the Android app the Kia Connect version was ported from; `reference-source/` is the Kotlin reference.
- The app is an OBD scanner: deep data for E-GMP cars (Kia EV6/EV9, Hyundai Ioniq 5/6/9, Genesis GV60/GV70e; `Vehicles.swift`), standard OBD-II for any other car. Live data, performance and lap timing, battery report and PDF, charge curves, trouble codes. Original artwork only: no maker logos, renders or trade names beyond saying which cars it works with. The old Kia Connect app is on branch `archive/kia-connect-full`; `docs/KIA-CONNECT-ARCHIVE.md` says what it did and where.
- Every build that adds or changes something the user would use gets a new `Release` at the top of `WhatsNew.releases` in `EV6Precondition/Views/WhatsNew.swift` (next number). That drives the in-app What's new.
- `docs/APP-STORE.md` is the App Store submission pack (listing, review notes, to-dos). The app name is in `AppInfo.name` and `project.yml`; the Pro unlock is off until `Store.paywallEnabled` is set.
- App Store Connect caps uploads per app per day (error ITMS-90382 "Upload limit reached"; the build succeeds and only Publishing fails). Batch changes and release to TestFlight a few times a day at most, not after every commit.
- Don't push each fix as it's made: every push to `main` runs the Codemagic build and uses build minutes. Commit locally and push in batches, when the user asks or when releasing.
