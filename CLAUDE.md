# Notes for Claude

- Work on and push to `main` directly. Don't create feature branches or pull requests unless asked.
- To ship to TestFlight: `git push origin main:release` (Codemagic's ios-testflight runs on pushes to `release`). Build results show as GitHub check runs on the commit.
- With `CODEMAGIC_API_TOKEN` set, `scripts/codemagic.sh start|status|cancel` drives Codemagic directly (e.g. `start ios-testflight main` rebuilds without a push). Never commit the token.
- Core logic lives in `PreconditionKit/` and must stay free of UIKit/SwiftUI so it builds and tests on Linux: `swift test --package-path PreconditionKit`.
- The iOS app (`EV6Precondition/`) is built by Codemagic (`codemagic.yaml`); the Xcode project is generated from `project.yml` by XcodeGen and isn't committed.
- HANDOVER.md, FUNCTIONS.md and TESTS.md describe the Android app being ported; `reference-source/` is the Kotlin reference.
- Every build that adds or changes something the user would use gets a tour step in `PreconditionKit/Sources/PreconditionKit/Guide/Guide.swift` (new or updated) and a new `GuideRelease` at the top of `releases` (next number) listing those steps. That's what drives the in-app What's new and tour.
- App Store Connect caps uploads per app per day (error ITMS-90382 "Upload limit reached"; the build succeeds and only Publishing fails). Batch changes and release to TestFlight a few times a day at most, not after every commit.
- Don't push each fix as it's made: every push to `main` runs the Codemagic build and uses build minutes. Commit locally and push in batches, when the user asks or when releasing.
