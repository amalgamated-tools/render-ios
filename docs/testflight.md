# TestFlight Test Information

Text to paste into App Store Connect → the app → TestFlight → Test Information.
Fields marked *external only* are needed only for external groups (Beta App Review).

## Beta App Description

> An unofficial iOS client for Render. Browse your workspaces, services, and datastores; check
> deploys, logs, events, and metrics; and take common actions such as redeploying, rolling back,
> suspending, resuming, scaling, and running cron jobs. Watch services to get a local
> notification when a deploy or cron run fails.
>
> Not made or supported by Render. Some actions change real resources on your Render account,
> so try them on something you don't mind restarting.

## What to Test

> Sign in, then move around your workspaces and services. Try anything you'd normally open the
> dashboard for. Report anything that looks wrong, is missing, or is slow, with a screenshot if you
> can (take a screenshot in TestFlight to send it with feedback).

Update this for each build with what changed.

## Feedback Email

`ios@veverka.net`

## Marketing URL (optional)

`https://github.com/amalgamated-tools/render-ios`

## Privacy Policy URL (*external only*)

`https://github.com/amalgamated-tools/render-ios/blob/main/PRIVACY.md`

## Beta App Review Information (*external only*)

**Contact:** Patrick Veverka, `ios@veverka.net`, plus a phone number.

**Sign-in required:** yes.

**User name / Password:** credentials for the throwaway Render demo account. Not the real
workspace; see below.

**Review notes:**

> The app signs in with Render's OAuth device-code flow, so there is no password field in the app.
>
> 1. Tap **Sign in with Render**. The app shows a short code. Tap **Open render.com to approve**.
> 2. In the browser, log in to Render with the user name and password above.
> 3. Check that the code matches, then approve. Return to the app; it signs in by itself within a
>    few seconds.
>
> The demo account has one workspace with a small web service, a cron job, and a Postgres
> database. Actions such as redeploy, suspend, and run cron job act on those real resources and
> are safe to try. The app is an unofficial, personal client for Render and is not affiliated
> with Render.

## Before the first external build

- [ ] Create the demo Render account and workspace, with a free web service, a cron job, and a
      Postgres database, so every screen has something to show. Turn off two-factor sign-in on it,
      or the reviewer can't log in.
- [ ] Merge `PRIVACY.md` so the privacy policy URL resolves.
- [ ] Replace the borrowed CLI OAuth client ID in `App/Auth/OAuthEnvironment.swift`.
