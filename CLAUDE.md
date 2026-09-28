# Notes for Claude

- Work on and push to `main` directly. Don't create feature branches or pull requests unless asked.
- Core logic lives in `PreconditionKit/` and must stay free of UIKit/SwiftUI so it builds and tests on Linux: `swift test --package-path PreconditionKit`.
- The iOS app (`EV6Precondition/`) is built by Codemagic (`codemagic.yaml`); the Xcode project is generated from `project.yml` by XcodeGen and isn't committed.
- HANDOVER.md, FUNCTIONS.md and TESTS.md describe the Android app being ported; `reference-source/` is the Kotlin reference.
