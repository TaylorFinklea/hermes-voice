# Bonjour Discovery + First-Launch Onboarding — Spec

> Discover the backend on the LAN via Bonjour and gate first launch behind a
> connection-tested onboarding screen. Tailscale MagicDNS remains the primary
> remote path; LAN Bonjour is a same-Wi-Fi convenience.

## Decisions (locked by user, 2026-05-28)

| Decision | Choice |
|---|---|
| Discovery | LAN Bonjour **with** a backend `_hermes-voice._tcp` advertiser + in-app browser (user picked "Add LAN Bonjour too"). |
| Onboarding presentation | **Full-screen** — `OnboardingView` replaces `MainView` until configured + test-connection passes (gated on `AppSettings.hasCompletedOnboarding`). |
| Token storage | Keep in **UserDefaults** (matches today). Keychain migration is a separate App-Store-hardening item — not in scope here. |

## Hard reality (drives the design)

- **mDNS does NOT traverse Tailscale** (link-local multicast 224.0.0.251:5353 vs. a point-to-point overlay). LAN Bonjour only finds the backend when phone + Mac are on the same Wi-Fi. The remote path stays a manually-entered Tailscale MagicDNS hostname.
- Therefore onboarding must support BOTH: (a) tap a discovered LAN backend, and (b) type a MagicDNS hostname / IP. Either way, **"Test connection" (GET /health) must pass before we save + dismiss onboarding.**

## Components

### Backend
- **Bonjour advertiser** — registers `_hermes-voice._tcp.local.` (port from config, TXT: version/scheme/path) on startup, unregisters on shutdown. Wired into the FastAPI lifespan, mirroring the schedules executor task. Guarded so a headless / no-LAN / zeroconf-missing environment is a silent no-op (must not break tests or crash startup). Optional `bonjour_enabled` config toggle (default true).
- **Dependency** — `zeroconf` added to pyproject (async API: `AsyncZeroconf`).
- **Test** — advertiser is a no-op when disabled / unavailable; create_app still builds; existing 41 tests stay green.

### iOS
- **`AppSettings.hasCompletedOnboarding`** — Bool persisted to UserDefaults (default false).
- **`HermesVoiceApp`** — WindowGroup gates: `OnboardingView` when not configured, else `MainView`.
- **`BonjourBrowser`** (new, ObservableObject) — discovers `_hermes-voice._tcp`, publishes `[DiscoveredBackend]` (name, host, port, scheme), resolves a selection to a usable URL. (Approach decided by research — NWBrowser+resolution vs NetService.)
- **`OnboardingView`** (new, full-screen) — discovered-backends list (one-tap fill) + manual MagicDNS/IP + token fields (reusing `HVField`) + "Test connection" (`HermesVoiceAPI.health()`); on success sets backendURL/authToken + `hasCompletedOnboarding = true`.
- **`project.yml` Info.plist** — add `NSBonjourServices: ["_hermes-voice._tcp"]` (REQUIRED iOS 14+ or browsing returns nothing). `NSLocalNetworkUsageDescription` already present.

## Verify

- Backend: `uv run pytest` → still green; advertiser no-ops under test.
- iOS: `xcodegen generate && xcodebuild ... build` → BUILD SUCCEEDED.
- On device (user): same Wi-Fi → backend appears in onboarding list, tap → test passes → MainView. Remote → type MagicDNS host → test passes → MainView.

## Out of scope

- Keychain token migration (separate hardening item).
- Re-running onboarding from Settings (Settings already edits URL/token; a "reset onboarding" affordance can come later).

## Technical approach (verified by `bonjour-research` workflow)

**Backend (`zeroconf>=0.140`, async API):**
- `app/mdns.py`: `start_mdns()` / `stop_mdns()`. Compute the LAN IPv4 via the **UDP-connect-to-TEST-NET trick** (`socket.connect(("192.0.2.1", 9))` → `getsockname()[0]`) — NOT `gethostbyname(gethostname())`, which returns the **Tailscale** `100.x` address on this host (verified live: returns `100.112.34.59` vs. the correct `10.15.109.127`). Guard against advertising loopback / `100.64.0.0/10` CGNAT.
- `ServiceInfo` MUST get explicit `parsed_addresses=[lan_ip]` (zeroconf does NOT auto-fill the A record). `ip_version=V4Only`. TXT: `{version, scheme, path, host?}`.
- Crash-safe: returns `None` (logs) on no-LAN `OSError`, `NonUniqueNameException`, or zeroconf `ImportError` (lazy import, mirroring `push.py`'s inline-aioapns pattern). Never breaks startup/tests.
- **Scheme** = `"https" if ssl_certfile and ssl_keyfile else "http"` (matches `__main__.py` exactly).
- **TLS resolution** (no cert bypass): optional `public_host` (env `HERMES_VOICE_PUBLIC_HOST`) advertised in TXT as `host`. iOS prefers it for URL building so an HTTPS Tailscale cert validates; empty → use resolved `.local`/LAN-IP host (fine for HTTP LAN backend).
- Config: `bonjour_enabled: bool = True` (`HERMES_VOICE_BONJOUR`), `public_host: str = ""`. Wired into existing lifespan, guarded `if bonjour_enabled and not auto_mock`. Lifespan doesn't run under TestClient → no test impact. Unit test covers `_in_cgnat`, `stop_mdns(None)` no-op, and `start_mdns` → None when LAN-IP is None.

**iOS (hybrid NWBrowser browse + NetService resolve — Apple-DTS-recommended):**
- `NSBonjourServices: ["_hermes-voice._tcp"]` in project.yml Info.plist — **MANDATORY** (without it discovery silently returns nothing). No multicast entitlement needed. `NSLocalNetworkUsageDescription` already present.
- `BackendBrowser` (ObservableObject): `NWBrowser` with `.bonjourWithTXTRecord` (TXT free at browse time → decide scheme/host before resolving); on selection, `NetService.resolve(withTimeout:)` scheduled on `.main` RunLoop → `hostName` + `port`. Build URL: `scheme://(txt.host ?? resolvedHost):port + path`, stripping the trailing dot from the `.local` FQDN. NetService is soft-deprecated but the only resolve-to-hostname path (Network framework has no resolve-without-connect API).
- `OnboardingView` mirrors SettingsView's `HVField` + `ping()` (`api.health()`); on success sets backendURL/authToken + `hasCompletedOnboarding=true`.

**Known limitation (documented for the user):** LAN discovery yields a working URL when the backend serves HTTP on the LAN, OR when `HERMES_VOICE_PUBLIC_HOST` is set to a cert-valid host (e.g. the ts.net name) and the device is on Tailscale. A bare HTTPS backend advertising only its LAN IP would cert-mismatch — manual MagicDNS entry remains the robust path there.

## Status — SHIPPED 2026-05-28

- Backend `3558dff`: `app/mdns.py` (AsyncZeroconf, UDP-connect LAN-IP, crash-safe lazy import), `config.bonjour_enabled`/`public_host`, lifespan wiring, `tests/test_mdns.py`. Backend suite **44/44**.
- iOS `35ff045`: `OnboardingView` (full-screen, gated on `hasCompletedOnboarding`), `BackendBrowser` (NWBrowser browse + NetService resolve, TXT-canonical-host preference), `NSBonjourServices` in Info.plist. iOS **BUILD SUCCEEDED**.
- **NOT yet on-device.** Verify on a real iPhone with a same-Wi-Fi Mac running the backend: (1) backend appears in onboarding within a few seconds; (2) tap → URL prefilled; (3) Test & Continue → MainView. Also verify the manual MagicDNS path.
- **User action for the HTTPS/Tailscale setup:** add `HERMES_VOICE_PUBLIC_HOST=<mac>.tailXXXX.ts.net` to `backend/.env` and restart, so a discovered backend's URL uses the cert-valid host. Without it, a discovered `https://<lan-ip>` would fail TLS hostname validation (no cert bypass by design).
- Token still in UserDefaults (Keychain migration remains a separate hardening item).
