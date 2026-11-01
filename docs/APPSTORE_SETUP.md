# App Store and TestFlight Setup

This repo is configured to publish `Tabata Ticker` to TestFlight from GitHub Actions.

## Bundle IDs

Register these explicit App IDs in the Apple Developer portal:

| Target | Bundle ID |
| --- | --- |
| iOS app | `com.merimerimeri.tabataticker` |
| Watch companion | `com.merimerimeri.tabataticker.watchkitapp` |
| Live Activity extension | `com.merimerimeri.tabataticker.liveactivity` |

The release workflow ships these IDs to TestFlight. The `Tabata Beta` scheme can build separate bundle IDs, so a beta could sit next to an App Store version, but no workflow uses it yet:

| Target | Beta Bundle ID |
| --- | --- |
| iOS app | `com.merimerimeri.tabataticker.beta` |
| Watch companion | `com.merimerimeri.tabataticker.beta.watchkitapp` |
| Live Activity extension | `com.merimerimeri.tabataticker.beta.liveactivity` |

The Xcode project generator sets the Apple team to `8G4H6268W7`, matching the existing MenuMines signing setup.

## App Store Connect

Create an app record for production:

| Field | Value |
| --- | --- |
| Platform | iOS |
| Name | `Tabata Ticker` |
| Bundle ID | `com.merimerimeri.tabataticker` |
| SKU | `tabataticker` |

Create a second app record for TestFlight:

| Field | Value |
| --- | --- |
| Platform | iOS |
| Name | `Tabata Ticker Beta` |
| Bundle ID | `com.merimerimeri.tabataticker.beta` |
| SKU | `tabataticker-beta` |

Because this app ships with an Apple Watch companion, fill in the required watchOS metadata and screenshots before external TestFlight testing or App Store submission.

## Apple Developer Assets

The release workflow signs with one long-lived Apple Distribution certificate and reuses an App Store provisioning profile for each target, creating a profile the first time through the App Store Connect API.

Never revoke that certificate while builds still need it. Doing so before processing fails with `ITMS-90721`, and doing so before TestFlight review fails with `ITMS-90035`.

Create the certificate once, which also sets its three `APPLE_DISTRIBUTION_CERT_*` secrets, with the same values as the secrets below. Run this again before it expires, about a year on. The next release makes matching profiles by itself.

```sh
ASC_ISSUER_ID=<Issuer ID> ASC_KEY_ID=<Key ID> ASC_API_KEY_PATH=AuthKey_<Key ID>.p8 \
  ruby Tools/app_store_connect_signing.rb create-distribution-cert
```

## GitHub Secrets

Add these repository secrets to `stephenmhoc/tabata-ticker`:

| Secret | Description |
| --- | --- |
| `ASC_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API key `.p8` |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `APPLE_DISTRIBUTION_CERT_BASE64`, `APPLE_DISTRIBUTION_CERT_PASSWORD`, `APPLE_DISTRIBUTION_CERT_ID` | Set by `create-distribution-cert` above |

The App Store Connect API key must be allowed to manage certificates, identifiers, profiles, and app uploads. Admin access is the least ambiguous option for this first setup.

## Release

Tag-based release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Manual release:

1. Open GitHub Actions.
2. Run `Release to TestFlight`.
3. Enter a version such as `1.0.0`.

The workflow:

1. Runs `swift test`.
2. Archives the iOS app with the embedded watch companion.
3. Exports an App Store Connect `.ipa`.
4. Uploads the `.ipa` to App Store Connect/TestFlight and waits for Apple to finish processing it.
5. Creates or updates the GitHub Release and attaches the `.ipa`.

## Keeping TestFlight Current

TestFlight builds expire after 90 days. `refresh-testflight.yml` checks weekly and, if the last release is 30 days old, releases the next patch version from `main`. If the distribution certificate has expired, that build fails: run `create-distribution-cert` above again.
