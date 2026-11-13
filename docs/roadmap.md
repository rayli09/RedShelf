# RedShelf completion target

Match the observable behavior and layout of the Rouge Apple TV app, using native tvOS controls and materials on the current OS. Use original branding and artwork. The public App Store screenshots show recommendations, note details and comments, a video feed, live streams, search, profile and account switching, and settings. They do not establish every behavior or setting; inspect the real app or obtain additional references before claiming full parity.

## Acceptance

- A user can securely sign in, restore a session, sign out, and switch accounts. Report confirmation or verification failures accurately.
- Recommendations, videos, live streams, search, notes, comments, personal content, likes and favorites operate against real data with appropriate loading, empty, error and pagination states.
- Note images, video playback, navigation, scrolling, focus, remote control and account changes work end to end on a real Apple TV. Preserve the user's intended account and never expose credentials in logs.
- Match the reference layouts, typography, spacing, imagery proportions and interactions across supported screens, with native `TabView` and platform controls; verify with real-device comparisons rather than assuming pixel parity.
- Supply a correctly configured, layered tvOS app icon and validate it on the device home screen.
- Build and tests pass, including authentication state and parser tests. Any unavailable upstream feature or unverified behavior must be reported explicitly.

## Current state

The native navigation and initial icon are implemented, but the current icon has not been visually confirmed on the device home screen. A user's confirmed QR scan reached the session-completion request, which returned error `-1`. An anonymous live probe later confirmed that the service issues an encrypted guest session key; this exchange and account-key rotation are now implemented and covered by local mock tests. QR generation and waiting have been tested anonymously, but the revised confirmed login has not been exercised with a real account. Search, note details, comments, and interactions have mock coverage only; actual feed, playback, and parity remain unverified. The app is not feature complete.
