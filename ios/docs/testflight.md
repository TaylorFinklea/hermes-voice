# TestFlight + APNs key — operator guide

Getting Hermes Voice onto TestFlight does triple duty: it registers the App ID
(so you can create a topic-scoped APNs key), it unblocks on-device testing
(real APNs tokens, real Watch, mic quality), and it's a daily-driver install.

## Prerequisites (already done in-repo)

- `aps-environment` entitlement (`HermesVoice/HermesVoice.entitlements`)
- `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`
- Automatic signing with Team `K7CBQW6MPG`

## 1. Create the App Store Connect record

1. <https://appstoreconnect.apple.com/apps> → **+** → New App
2. Platform: iOS. Name: "Hermes Voice" (or whatever; can differ from bundle).
3. Bundle ID: select/create `dev.finklea.harnessvoice`. If it's not in the
   dropdown, register it first at
   <https://developer.apple.com/account/resources/identifiers/list> — and
   when you do, **check the Push Notifications capability**.
4. SKU: anything unique, e.g. `hermesvoice`.

## 2. Archive + upload

**Routine releases — use the script:**
```bash
./scripts/release.sh            # bump build, archive, upload to TestFlight, commit
./scripts/release.sh --patch    # also bump 1.0 → 1.0.1 (for an App Store review)
./scripts/release.sh --no-commit
```
It bumps `CURRENT_PROJECT_VERSION` in `project.yml`, regenerates the project,
archives Release for generic iOS, and uploads via the account-wide App Store
Connect API key (`~/.appstoreconnect/AuthKey_J79935N6P6.p8`, shared with your
other apps). An agent can run this for you. Requires the App ID to already
exist — so do the first archive through Xcode (below) once, then use the
script thereafter.

**First-ever archive (or if the script's signing fails) — via Xcode GUI**
(handles the embedded Watch app cleanly):

1. Open the project: `open ios/HermesVoice/HermesVoice.xcodeproj`
2. Make sure you're signed into Xcode with the Apple ID on Team `K7CBQW6MPG`
   (Xcode → Settings → Accounts).
3. Destination: **Any iOS Device (arm64)** — not a simulator.
4. **Product → Archive**. On first archive, Xcode registers the App ID +
   creates distribution provisioning profiles, and **enables the Push
   Notifications capability on the App ID** (because of our entitlement).
   This is the step that "surfaces the topic" for the APNs key.
5. When the Organizer opens: **Distribute App → TestFlight (Internal Only)**
   → follow prompts → Upload.
6. Wait for "Processing" to finish in App Store Connect → TestFlight tab
   (usually 5-15 min). Add yourself as an internal tester. Install via the
   TestFlight app on your phone.

Command-line alternative (if you prefer; watchOS archives are fussier this way):
```bash
cd ios/HermesVoice
xcodebuild -project HermesVoice.xcodeproj -scheme HermesVoice \
  -destination 'generic/platform=iOS' -archivePath build/HermesVoice.xcarchive archive
xcodebuild -exportArchive -archivePath build/HermesVoice.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
# then upload build/export/*.ipa via Transporter.app or `xcrun notarytool`/altool
```
(No `ExportOptions.plist` exists yet — ask and I'll generate one for app-store export.)

## 3. Create the (topic-scoped) APNs key

Now that the App ID has Push enabled:

1. <https://developer.apple.com/account/resources/authkeys/list> → **+**
2. Name "Hermes Voice push", check **Apple Push Notifications service (APNs)**.
   To scope to just this app, choose the topic restriction and select
   `dev.finklea.harnessvoice`. (If you'd rather a team-wide key, leave it
   unrestricted — works for all your apps but less least-privilege.)
3. Register → Download the `.p8` (one-time). Note the Key ID.
4. Place it:
   ```bash
   mkdir -p ~/.hermes-voice
   mv ~/Downloads/AuthKey_*.p8 ~/.hermes-voice/apns-key.p8
   chmod 600 ~/.hermes-voice/apns-key.p8
   ```

## 4. Wire the backend

Append to `backend/.env` (Claude will hand you a `! cat >>` one-liner so it
never reads your .env):
```
APNS_KEY_PATH=/Users/tfinklea/.hermes-voice/apns-key.p8
APNS_KEY_ID=<10-char Key ID>
APNS_TEAM_ID=K7CBQW6MPG
APNS_BUNDLE_ID=dev.finklea.harnessvoice
APNS_USE_SANDBOX=false        # TestFlight builds use PRODUCTION APNs
```

**Important environment detail**: A TestFlight build is a *Release* build, so
the app reports `environment=production` to the backend (via `#if DEBUG` in
`NotificationManager`) and its entitlement is promoted to `production` on
archive. So set `APNS_USE_SANDBOX=false` for the TestFlight install. If you
*also* run a debug build from Xcode on a device, that one uses sandbox — the
backend keys push environment per registered device, so both can coexist.

Restart the backend, then in the app: Settings → Notifications → Allow
notifications. Verify a device row landed:
```bash
sqlite3 ~/.hermes-voice/schedules.db \
  'select platform, environment, substr(token,1,8) from devices;'
```

## 5. Smoke test

Create a 1-minute schedule (Settings → Manage schedules → +), lock the phone,
wait. You should get a push with the Hermes chime; tap to hear it.
