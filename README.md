# AgentBell

AgentBell is a native macOS menu-bar app that watches local ChatGPT
Desktop/Codex and Claude Desktop/Claude Code activity and sends privacy-aware
notifications. It has no third-party runtime dependencies.

## Requirements

- Apple silicon Mac
- macOS 13 or newer

## Download and install

Download the `v1.3.0` release DMG and drag `AgentBell.app` to
`/Applications`. This release is ad-hoc signed with a free development
identity. It is not signed with Apple Developer ID and is not notarized, so
macOS may warn that the developer cannot be verified. See
[macOS says AgentBell can't be opened?](#macos-says-agentbell-cant-be-opened)
before opening it.

On first launch:

1. Allow notifications when macOS asks.
2. Open the menu-bar bell → **Settings** → **Integration**.
3. Choose **Install Integration**.
4. If you use Codex, open `/hooks` once and approve the new non-managed hooks.

Integration is designed to be a one-time setup per Mac. It preserves unrelated
Codex and Claude configuration, creates timestamped backups, and installs the
optional VS Code focus companion. The Integration screen shows separate health
for Codex, Claude Code, and VS Code. Use **Repair Integration** if a provider
reports missing hooks; repeating the action is safe.

Open Settings → **Testing** to send a local test alert. Focus modes and macOS
notification settings can still suppress a visible banner.

## macOS says AgentBell can't be opened?

That warning is expected for this free, non-notarized build. It means macOS
cannot verify the publisher; it does not mean that AgentBell was Apple-trusted.

1. In Finder, open `/Applications`.
2. Control-click `AgentBell.app` and choose **Open**.
3. Confirm **Open** in the dialog.

If macOS still blocks it, try opening AgentBell once, then go to **System
Settings → Privacy & Security**. Scroll to **Security**, choose **Open Anyway**
for AgentBell, authenticate, and open it again.

Do not disable Gatekeeper globally or remove quarantine from arbitrary copies.
If macOS says the app is damaged, or the checksum/signature does not match the
release assets, delete that copy and download the DMG again.

## Phone alerts with ntfy

Phone alerts are optional and off by default. AgentBell uses `https://ntfy.sh`;
it does not run a server on the Mac.

On the first launch of a new Mac install, AgentBell generates a private topic
from 256 bits of cryptographically secure randomness and stores it in that
Mac's Keychain. The topic is reused on that Mac so setup is one-time. A new
Mac or a reset of AgentBell settings gets a new topic; downloading the same
DMG again on the same Mac does not rotate it.

To connect a phone:

1. Open Settings → **Phone** and enable phone alerts.
2. Choose **Connect Phone…** and scan the QR code on the intended phone.
3. Subscribe to the opened topic in the ntfy app and allow phone notifications.
4. Return to AgentBell and choose **Test Phone Alert**. Confirm that the
   notification actually arrives on the phone.

Treat the topic and QR code like a password. On public `ntfy.sh`, an
unprotected topic is a bearer-like secret rather than a server-side access
control. Optional ntfy publish tokens are stored only in Keychain. Phone
messages contain generic state by default; sanitized titles and previews are
an explicit opt-in. Full prompts, transcripts, file contents, paths, session
IDs, and navigation metadata are not sent. See [SECURITY.md](SECURITY.md) for
the detailed privacy and distribution limits.

## Privacy

Nothing leaves the Mac while phone alerts are disabled. When enabled, AgentBell
sends bounded notification data to ntfy over HTTPS and keeps retry state in a
user-only local directory. Native notification details are also off by default.
macOS controls notification banners, Focus behavior, login-item approval,
Accessibility, and Automation permissions.

## Build from source

```sh
swift test --arch arm64
/bin/zsh Scripts/build-app.sh release
```

The app is built at `.build/AgentBell.app`. To create a free distribution DMG,
use a release key stored outside the repository:

```sh
AGENTBELL_DISTRIBUTION_MODE=adhoc \
AGENTBELL_RELEASE_PRIVATE_KEY="/path/to/release-private.pem" \
/bin/zsh Scripts/build-dmg.sh release
```

For Apple-trusted distribution, use a Developer ID Application identity and
notarize the DMG; the build script fails closed without those credentials.

## Uninstall

Open Settings → **Info** → **Uninstall AgentBell…**. AgentBell removes only its
own hooks, VS Code companion, login item, notifications, and local state.
Configuration backups are kept.
