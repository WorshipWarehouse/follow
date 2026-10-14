# Download Follow for iPhone

[Download Follow-unsigned.ipa](https://github.com/WorshipWarehouse/follow/raw/refs/heads/main/output/Follow-unsigned.ipa)

This is a Release build of Follow with its Share extension, for iOS 17 or later. The version and SHA-256 checksum are in [download.json](download.json).

**This IPA is unsigned. It cannot be installed by tapping it in Safari or Files.** Sign it with your own Apple development credentials using a compatible sideloading tool, or build the source in Xcode. The download does not include the developer's provisioning profiles, device registrations, or signing credentials.

## Install with Xcode

1. Download or clone this repository on a Mac and open `Follow.xcodeproj`.
2. Sign into Xcode → Settings → Apple Accounts.
3. Select the **Follow iPhone Sharing** scheme. In Signing & Capabilities, choose your own team for **FollowPersonalSharing** and **FollowPersonalShare**, and change their bundle identifiers to unique identifiers belonging to you. The extension identifier must start with the app identifier.
4. Connect and unlock your iPhone, select it as the run destination, and press Run. Enable Developer Mode and trust your developer certificate if iOS requests it.

Free Personal Team profiles expire after **seven days**. Rebuild/reinstall before expiration; refreshing signing preserves data when using the same app identifier. Do not delete the app to refresh it, because deletion removes its local library. Signing a downloaded IPA does not bypass expiration.

For general users to install without a Mac or signing tools, the developer must distribute through Apple's supported channels, such as TestFlight or the App Store, using an Apple Developer Program membership. TestFlight builds also expire after 90 days; App Store distribution avoids the weekly development-profile limit.

## Rebuild this download

With Xcode and Python 3 installed, run `./scripts/build-download.sh` from the repository. It produces this IPA and checksum without signing or provisioning profiles. Temporary build files are created outside the repository.

Apple references: [Personal Team expiration](https://developer.apple.com/help/account/basics/about-your-developer-account), [distribution options](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases), and [TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
