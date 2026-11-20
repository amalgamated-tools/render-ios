# Privacy Policy

**Effective:** November 20, 2026

This policy covers the iOS app built from this repository, an unofficial client for
[Render](https://render.com). The app is a personal project by Patrick Veverka. It is not made,
endorsed, or supported by Render.

## The short version

The app does not collect, sell, or share any data. It has no analytics, crash reporting,
advertising, or tracking, and there is no server of mine that it talks to. Everything it does
happens on your device or between your device and Render's API.

## What the app connects to

The app sends requests only to Render (`api.render.com`) to sign you in and to show and change
your Render resources. Those requests are covered by
[Render's privacy policy](https://render.com/privacy), not this one. Links that open in your
browser, such as the Render dashboard or documentation, are covered by those sites' policies.

## What the app stores on your device

- **Sign-in credentials.** Your Render sign-in token, or an API key if you sign in with one, is
  kept in the iOS Keychain. An organization audit log API key is kept there too, if you add one.
  These are not synced through iCloud Keychain.
- **Preferences.** The workspace and project you last selected, the services you chose to watch
  for failures, and the time of the last event the app checked for each watched service.

None of this is sent anywhere except to Render, as part of the requests above.

## Notifications

Failure alerts are local notifications. The app checks Render in the background on your device
and shows an alert itself. No push notification service is involved, and no device token is
collected.

## Removing your data

Signing out removes your sign-in token or API key from the Keychain and revokes the sign-in
session with Render. It does not remove an organization audit log API key: remove that from the
Organization Audit Log screen with **Remove Key from This Device**. iOS can keep Keychain items
after an app is deleted, so do both before deleting the app if you want them gone. You can also
revoke the app's access at any time from your Render account settings, and revoke an audit log
API key from your organization's settings.

## Children

The app is not directed at children under 13.

## Changes

Changes to this policy will be committed to this file, and its history is public in this
repository.

## Contact

Questions: ios@veverka.net
