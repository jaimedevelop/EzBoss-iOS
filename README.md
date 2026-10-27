# EzBoss iOS

SwiftUI iOS 17+ sign-in foundation using official Auth0.swift 2.25.0.
Open `EzBoss.xcodeproj`; the source project is now unpacked and versionable.
The original zip remains untouched. Existing source relocation is preserved.

## Build

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project EzBoss.xcodeproj -scheme EzBoss -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ezboss-ios-derived CODE_SIGNING_ALLOWED=NO build
```

The checked-in Swift Package resolution pins Auth0 and its dependencies. Xcode
needs network access on the first build. Simulator builds require no Apple team.

## Set up live sign-in (owner: Joaquin)

1. In Xcode Settings → Accounts, sign in with your Apple developer account.
   Select the intended team under target Signing & Capabilities. Register and set
   the intended bundle identifier. `local.ezboss.development` works for Personal
   Team development login with its registered custom-scheme callback; choose the
   final production identifier before distribution. Paid membership is not needed
   for this development login.
2. In the intended staging Auth0 tenant create **EzBoss iOS Staging**, application
   type **Native**, token endpoint authentication method **None**. Enable the
   intended user connection, Authorization Code and Refresh Token grants, refresh
   token rotation and API offline access. No client secret belongs in this app.
3. Add this exact URL to both Allowed Callback URLs and Allowed Logout URLs,
   substituting the final bundle ID and tenant domain:
   `BUNDLE_ID://DOMAIN/ios/BUNDLE_ID/callback`.
   The app registers its bundle identifier as the URL scheme. The SDK uses
   ASWebAuthenticationSession and authorization code with PKCE.
4. Copy `Config/Local.xcconfig.example` to ignored `Config/Local.xcconfig` and
   fill only `AUTH0_DOMAIN` (host only), `AUTH0_CLIENT_ID` (iOS Native application,
   not the web/Android/management client), `AUTH0_AUDIENCE` (existing API identifier)
   and `API_BASE_URL` (isolated HTTPS staging API root, including any mount prefix).
   Keep the `$()` slash separator shown in URL examples: xcconfig treats `//` as a
   comment. `Info.plist` references those four public build settings. Do not copy
   server `.env` files, client secrets, management credentials or tokens here.
   Xcode/CI build-setting overrides can also supply the public values.
5. Confirm the staging API verifies this tenant's issuer and audience. Link a
   controlled test identity to the dedicated TEST user's `auth0Id`. Do not invent
   tokens, bypass verification or automatically create company membership.
6. Pair/unlock your iPhone, enable Developer Mode and trust the Mac. Run the
   signed Debug build from Xcode. Test owner and employee accounts separately.

Until the values are set, sign-in and API actions remain disabled. The app stores
credentials only through the SDK Keychain manager and requests offline access.
It restores/renews sessions on launch and foreground, fetches `users/me`, displays
only active accounts, and removes visible identity on access failures. API
redirects are refused, and response bodies/tokens are never logged or displayed.
Logout clears local credentials even if browser logout is cancelled. It does not
claim server-side refresh-token revocation or immediate invalidation of already
issued tokens. Business permissions remain enforced by the API; no company or
business screen has been accepted yet.

## Runtime acceptance still required

- Sign in and read the correct owner/employee identity through staging `/users/me`.
- Cancel login, retry network failure and verify unlinked-account recovery.
- Relaunch and expire the access token to exercise refresh rotation.
- Deny suspended/revoked accounts; no protected data should remain visible.
- Sign out, relaunch, then sign in with a different account and verify isolation.
- Verify callback/logout URLs on simulator and signed physical device.

Build success proves compilation only. Live Auth0, staging and signing are pending
account setup. Auth0 reference: https://github.com/auth0/Auth0.swift/tree/2.25.0


## Navigation and repeatable checks

Home and Account access form the initial protected navigation stack. It exists
only after `/users/me` returns an active, valid account; sign-out, failed access
and foreground revalidation remove the protected stack and its route state.
Business modules are later increments, and account role display does not grant
permissions. The reusable API client rejects redirects, uses ephemeral networking
without cookie/cache persistence, and distinguishes 401, 403, 404, inactive,
malformed and unavailable account responses. Login and logout explicitly share
the callback derived from the actual app bundle ID and configured tenant.

The Swift package compiles the same core source files used by the app. Its tests
run on the Mac without starting a simulator or calling Auth0/staging:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --scratch-path /tmp/ezboss-core-tests --jobs 2
python3 scripts/check-config.py
python3 scripts/check-config.py --app /tmp/ezboss-ios-derived/Build/Products/Debug-iphonesimulator/EzBoss.app
```

Before live acceptance, use `--require-config` with `--app` to require populated
public values. For distribution also use `--require-release-identity` to reject
the temporary bundle identifier. Personal Team development login can use it. The checker
rejects unknown entries in Local.xcconfig and server credential/token fields in
Info.plist without printing their values. Keep this check in the build/release
verification sequence. Both app runtime validation and the checker reject missing
or malformed configuration; an unconfigured bootstrap build is allowed with
sign-in disabled. These checks cannot establish Native app ownership, provider
allowlists or real callback delivery; verify those in Auth0 and on the device.

After any simulator runtime checks, shut down the simulator immediately and
verify that it stopped. The commands above only compile/test and do not boot one.


### Testable session lifecycle

`EzBoss/Core/Session.swift` owns identity-gated session state; the app supplies an
Auth0 adapter using the same Keychain manager and PKCE browser flow. Token reads
request 30 seconds of validity to allow time for the API request. Session tests
exercise restore/renewal failure, login cancellation, denied/missing identity,
service retry, overlapping actions, failed secure removal and cancelled browser
logout. Local logout suppresses foreground restoration even if secure deletion
fails; its notice instructs the operator to retry. No server token revocation is
claimed. See `../docs/launch/OCTOBER_28_NATIVE_SESSION.md` for verification and live gates.


### October 27: configured iPhone build

The current ignored `Config/Local.xcconfig` contains the iOS Native application's
public domain/client ID from the supplied Auth0 setup, the existing API audience
and the same HTTPS Railway backend used by Android. This backend's hostname is
labelled production; it is not a newly verified isolated staging environment.
No separate `Auth0.plist` is needed because the adapter explicitly passes domain
and client ID to the SDK. The SDK is already linked as an app-target dependency.

The registered development callback/logout URL is:
`local.ezboss.development://dev-jllkm3kbdoo3n5cx.us.auth0.com/ios/local.ezboss.development/callback`.
The iOS app's user-delegated API grant was enabled with Joaquin's explicit approval;
no machine-to-machine or anonymous access was granted. A public S256 PKCE authorize
request now reaches `/u/login` without an OAuth error. Actual user authentication,
API identity and renewal still require entering credentials on the phone.

Rebuild with your connected iPhone selected in Xcode (Run / Cmd-R), open EzBoss,
and tap Sign in. Use an existing EzBoss account linked to the API; an Auth0-only
account cannot open protected screens without a corresponding active API user.


### Fresh-install secure removal fix

The SDK returns false when its Keychain item does not exist. The app now checks
that exact service/account after an unsuccessful SDK deletion: only Keychain
`errSecItemNotFound` counts as already cleared. A remaining item or any actual
Keychain access error still blocks account switching. Host regression tests and
a signed device build pass; retry sign-in on the installed update for phone acceptance.
See `../docs/launch/OCTOBER_27_IOS_AUTH0_SETUP.md` for the setup and verification record.
