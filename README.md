# Turnring

Turnring is a small native macOS menu-bar app that watches local Codex and
Claude Code lifecycle hooks and posts
privacy-preserving native notifications. It has no third-party runtime
dependencies. Optional phone alerts publish minimal generic state by default;
sanitized task titles and previews are an explicit opt-in.

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

The local build is written to `.build/Turnring.app`. It is ad-hoc signed with
hardened runtime and verifies its complete bundle signature before processing
events. Local mode intentionally does not create a DMG.

Public Developer ID distribution is fail-closed. It requires a Developer ID
Application identity and a `notarytool` Keychain profile:

```sh
TURNRING_DISTRIBUTION_MODE=developer-id \
TURNRING_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
TURNRING_NOTARY_PROFILE="turnring-notary" \
/bin/zsh Scripts/build-dmg.sh release
```

The build signs, notarizes, staples, mounts, and verifies the exact DMG and
app. The DMG is written to `outputs/` with a SHA-256 manifest.

If an Apple Developer Program membership is unavailable, Turnring supports
a free/ad-hoc distribution mode. macOS cannot verify the publisher or notarize
that build. The mode therefore requires a separate long-lived release key and
produces a documented DMG plus a detached signature. See
[SECURITY.md](SECURITY.md) for key creation, verification, and the limits of
this fallback.

The current release is 1.3.0 RC (build 30). Turnring intentionally has no
network-based automatic updater; releases are replaced as app bundles so the
runtime remains dependency-free and offline.

The product icon uses the same flat interlocking-ring SVG as the menu bar,
with a silver ring and a single blue accent. The canonical source lives at
`Resources/Brand/TurnringMark.svg`; the build script rasterizes it into the
native multi-resolution `AppIcon.icns` bundled with the application. Dashboard
provider icons are bundled vector SVGs. The Codex mark is sourced from the current Codex vector listing on
DBLogo and remains an OpenAI trademark. The Claude symbol is the CC0 vector
published on Wikimedia Commons from Anthropic's mark.

## First run

1. Open `Turnring.app`.
2. Complete the short onboarding flow in the rounded menu-bar panel. Phone alerts
   and Sensitive Previews are both off by default.
3. Choose Codex, Claude Code, or both. Turnring installs only the selected
   provider hooks.
4. For Codex Desktop, open Settings, choose **Hooks** under **Coding**, and
   approve all six hooks. For Codex CLI, run `/hooks` and approve all hooks.
5. Allow notifications when macOS asks. Accessibility is optional and is
   never requested automatically; grant it manually in System Settings only
   if you want best-effort window matching for hosts without stable IDs.

Open Settings → Testing to exercise the complete local notification path.
Testing includes a generic alert, every supported Codex and Claude Code
surface, and an all-apps action. Every test also creates a non-navigable
dashboard entry. If macOS accepts an alert but no banner appears, turn off
Focus or allow Turnring in the active Focus mode.

On macOS 26 and later, Turnring's top-level controls use AppKit's native
Liquid Glass views and container grouping. Earlier macOS versions use the
native material fallback, and Reduce Transparency uses a solid charcoal
surface. The menu itself is a transparent borderless panel whose visible
surface owns the rounded mask, rather than a square popover with rounded
content placed inside it.

Turnring safely merges its entries into `~/.codex/hooks.json` and
`~/.claude/settings.json`, preserving unrelated configuration and creating
timestamped backups. Hook configuration points to a stable launcher in
Turnring's private Application Support directory. Turnring safely refreshes
that launcher to the current signed app bundle after an update or move, so
hooks do not need repair on every startup. The bundled VS Code extension is
installed only by onboarding or the Install Integration action in Settings →
Integration. That section shows health only for selected providers and
contains Repair Integration.

Codex and Claude Code approval dialogs are observed through `PermissionRequest`
hooks and appear as **Needs attention**. Codex approval alerts are emitted only
when the effective reviewer is the user; Auto/Approve for me and Full Access
are suppressed. Input pickers are observed through narrowly matched
`PreToolUse` hooks. Alerts use plain actions such as **Question**, **Plan
approval**, **Permission**, **Input needed**, and **Usage limit**, never raw
hook or tool identifiers. Detailed question alerts keep only the first
sanitized question plus the number of questions. They never retain choices,
answers, or plan contents. Permission previews describe the requested action
in human language and include only an allowlisted, redacted command, path,
query, or URL when Sensitive Previews is enabled.

When first focusing a Ghostty session, macOS may separately ask whether
Turnring can control Ghostty. That Automation permission lets Turnring
capture and focus Ghostty's stable terminal ID; it is distinct from
Accessibility permission.

Open the dashboard's gear button for Settings. General contains launch at
login, quit confirmation, and dashboard-history retention. Terminal and test
items are removed after 5 minutes by default; cleanup can be disabled or set
from 1 minute through 7 days. Active work and unresolved Needs attention
items are never removed automatically.

Notifications contains the privacy switch and controls for Codex Desktop,
Codex CLI, Codex VS Code, Claude Code CLI, and Claude Code VS Code. Desktop
agent surfaces that do not emit reliable hooks are not offered. Disabling a
supported surface suppresses its alerts while retaining its local session
history and navigation. Minimum task duration defaults to 0 seconds (always)
and is editable from 0 through 3,600 seconds. Info contains the installed
version, privacy summary, and **Uninstall Turnring…** action.

Phone contains optional ntfy delivery. Turnring uses the hosted `ntfy.sh`
service; it does not launch a local server or background ntfy process.
On first launch, Turnring generates a separate private topic using 256 bits
from macOS's cryptographically secure random generator. **Connect Phone…**
shows an explicit QR code for the private HTTPS topic so the user can open it
on the intended iOS or Android device, subscribe in ntfy, and allow phone
notifications. **Test Phone Alert** then verifies actual receipt and adds a
matching entry to the dashboard; a successful publish alone is not presented
as proof that a phone subscribed. Turnring makes no network request while
Phone alerts are disabled. By default, phone
payloads contain only the app surface and generic state. The optional details
switch adds the sanitized task title and preview. Phone payloads never contain
full prompts, transcripts, session IDs, working directories, file contents,
or navigation metadata.

### Secure topic design

- Topics are generated locally as `turnring-` plus 43 unpadded base64url
  characters: 256 bits of CSPRNG entropy in 53 total characters, within
  ntfy's 64-character topic limit.
- Turnring does not query ntfy to ask whether a generated topic exists.
  ntfy topics are created implicitly, and a remote check would reveal the
  bearer-like topic while still leaving a race before first publish.
- The topic is stored as a device-only generic-password item in macOS
  Keychain. Older values are migrated only when they match the complete
  256-bit generated format. Any weaker or malformed value is deleted and
  replaced, then removed from UserDefaults. Incompatible pre-release
  hexadecimal topics are also rotated so phone clients can subscribe.
- The durable retry outbox does not contain the topic. It is retrieved from
  Keychain only when a request is built.
- The topic is never included in logs, hook configuration, or process
  arguments. It is sent in the HTTPS JSON request required by ntfy and is
  placed in an HTTPS setup URL only after the user explicitly opens
  **Connect Phone…**.
- Settings shows only a masked topic identifier. The explicit Copy Topic
  action places the full value on the clipboard and clears it after 60 seconds
  if it has not already been replaced.
- Uninstall deletes both the topic and optional publish token from Keychain.
- If secure randomness or Keychain access fails, Turnring does not create an
  insecure fallback topic and phone publishing fails closed.

Settings → Info contains a confirmed **Reset All Settings…** action. It
returns notification, privacy, timer, phone, quit, and login choices to their
defaults, removes the ntfy token, and rotates the private topic. Integration
hooks and dashboard history remain intact. Since rotation invalidates the old
phone subscription, Turnring explicitly directs the user through Connect
Phone again.

On public `ntfy.sh`, an unprotected topic name effectively acts as the shared
secret because anonymous read and write access are enabled. The 256-bit topic
makes guessing or accidental collision computationally infeasible, but it is
not a server-side reservation and absolute global uniqueness cannot be
guaranteed. For enforceable read/write authorization, reserve and protect the
topic in ntfy or use an authenticated self-hosted server with deny-by-default
ACLs.

Protected ntfy topics can use an optional publish access token. Turnring
stores that token as a device-only generic-password item in macOS Keychain,
loads it only while publishing, and sends it only in the
`Authorization: Bearer …` header. The token is never stored in UserDefaults,
the durable outbox, URLs, hook configuration, process arguments, or logs.
The publish token uses a secure entry field and is never revealable in the UI.
The eye button belongs to the random ntfy topic. It reveals the topic for at
most 60 seconds, masks it when Turnring loses focus or detects supported
capture software, and marks the containing window as excluded from macOS
window sharing and capture while visible. Failed phone deliveries use bounded
backoff and are discarded after eight attempts or 24 hours.

Native task titles and previews are also off by default. Enable **Show
sensitive titles and previews** in Settings → Notifications to see sanitized
titles, questions, commands, and filenames while using the Mac. The setting
has an in-app privacy warning because macOS notifications may appear on a
lock screen or shared display. Detailed preview length is configurable from
10 through 120 characters, with 120 as the default. With details off, the
dashboard and native alerts use generic state descriptions instead of an
empty “No preview yet” placeholder. Turnring sends generic native content
whenever the screen is locked and removes already-delivered detailed Turnring
notifications when it observes a lock. For defense in depth, set System
Settings → Notifications → Show previews to **When Unlocked**; macOS owns that
system policy and apps cannot change it.

## Privacy and behavior

### What leaves the Mac

Nothing leaves the Mac while Phone alerts are off. When they are on, Turnring
sends an HTTPS POST to `https://ntfy.sh` containing the random topic, an opaque
deduplication identifier, priority, app surface, generic event state, and
duration when known. If phone details are explicitly enabled, it additionally
sends the sanitized conversation title and bounded preview. If authentication
is configured, the Keychain token is included only as an Authorization header.
No source files, full prompts or responses, absolute paths, command output,
environment variables, repository remotes, session IDs, process metadata, or
navigation metadata are sent.

- Session history contains provider, session ID, project path/name, state,
  timestamps, process birth identity, focus metadata, an 80-character
  whitespace-normalized conversation title from Codex or Claude Code's local
  session metadata, and sanitized result, approval, or question previews
  bounded to 120 characters.
- Full prompts, full responses, file contents, patches, question choices and
  answers, complete tool inputs, and transcript contents are never retained.
  Approval command previews may retain a redacted, truncated command line.
- Turnring does not read source files in a repository. Title resolution reads
  only bounded title metadata from Codex's session index and Claude Code's
  local session records; unrelated transcript entries are ignored and never
  persisted.
- A central sanitizer strips controls, bidirectional overrides, common token
  and credential shapes, URL credentials, home-directory usernames, and email
  addresses from outbound detail text.
- Native Notification Center routing metadata contains only an opaque hash,
  never a raw provider or session identifier.
- Runtime files use user-only permissions under
  `~/Library/Application Support/Turnring`.
- The ntfy topic and optional token are stored device-only in macOS Keychain.
  Neither secret is persisted in UserDefaults or the retry outbox.
- Only PIDs learned from hook events are checked for liveness; Turnring does
  not continuously scan the process table. The event queue has a 60-second
  recovery fallback, and PID checks run every 15 seconds only while a tracked
  agent is active.
- Queue batches are claimed before processing and replayed after a crash.
  Persisted event deduplication prevents a replay from producing a second
  alert.
- Turnring contains no third-party runtime dependencies and emits no raw hook,
  request-body, token, path, or transcript logs.
- Claude `StopFailure` events such as rate limits and provider errors are
  reported as Failed. Explicit Codex network/rate-limit stops and unexpected
  tracked-process exits are also reported as Failed.
- Sleep pauses process liveness checks. After wake, Turnring clears stale
  suspicions and requires fresh failed birth-identity checks before reporting
  a process that disappeared while the Mac slept.
- Finished rows and alerts include the elapsed turn duration when a matching
  start event was observed, for example `Finished (18m 42s)`.
- The duration threshold affects both native and optional phone alerts;
  shorter work remains visible in local dashboard history.
- Dashboard history consolidates session IDs belonging to the same exact
  provider process birth and hides lifecycle-only start/end records, avoiding
  duplicate task cards without conflating a reused PID.
- Phone deliveries are persisted before sending, retried with bounded backoff
  after offline, DNS, TLS, rate-limit, and server failures, and use a stable
  opaque ntfy sequence identifier so ambiguous retries update one phone alert.
- A single-instance lock prevents two Turnring processes from concurrently
  changing the queue or dashboard state.
- A live session is focused, never resumed into a second process.
- Swipe left on a dashboard session and press **Clear** to remove that row and
  its matching delivered alerts without ending the underlying agent session.
  The row tilts and falls backward before leaving the dashboard.
- The header **Clear** button applies the same fall-back animation to every
  visible session before clearing the complete history.
- Completed, failed, ended, and synthetic test rows expire after 5 minutes by
  default. The interval and automatic cleanup switch are in Settings →
  General; active and unresolved attention rows do not expire.
- Quit is visually destructive and asks for confirmation by default. The
  confirmation can be disabled in Settings → General.
- The dashboard footer shows the installed version and build number.
- Test-alert and integration-repair result messages disappear automatically
  after approximately five seconds.
- Terminal.app sessions are matched to their exact tab by TTY. Ghostty
  sessions are matched by the stable terminal ID captured at a hook event.
  If either identifier is unavailable, Turnring falls back to activating the
  original app and matching its window.

## Uninstall

Open Settings → Info and choose **Uninstall Turnring…**. It removes only
Turnring-owned hooks, uninstalls the VS Code companion, unregisters login
startup, clears Turnring state, and moves the app to Trash. Configuration
backups are kept.
