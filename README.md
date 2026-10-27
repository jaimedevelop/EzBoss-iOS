# EzBoss iOS bootstrap

Minimal native SwiftUI application, iOS 17+, display name EzBoss. No authentication,
API, payment or push implementation is claimed. No customer data or credentials
are embedded. `local.ezboss.development` is a temporary simulator bundle identifier;
replace it before Auth0 callbacks, signing or distribution. Apple team is pending.

Simulator build (no signing required):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project EzBoss.xcodeproj -scheme EzBoss -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ezboss-ios-derived CODE_SIGNING_ALLOWED=NO build
```

Next: register final identity/team and Auth0 Native application; implement PKCE
login, secure session storage, `/users/me`, seeded list/detail and logout; then
execute selected iOS protocols in `../NewEzBoss/docs/launch/first-tranche.json`.
