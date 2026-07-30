# AgentBell

AgentBell is a small native macOS menu-bar app that watches local ChatGPT
Desktop/Codex and Claude Desktop/Claude Code lifecycle hooks and posts
privacy-preserving native notifications. It has no third-party runtime
dependencies. Optional phone alerts publish minimal generic state by default;
sanitized task titles and previews are an explicit opt-in.

## Requirements

- Apple silicon Mac
- macOS 13 or newer
- Swift 6 / Xcode command-line tools to rebuild

## Build

```sh
swift test --arch arm64
/bin/zsh Scripts/build-app.sh release
```

The local build is written to `.build/AgentBell.app`. It is ad-hoc signed with
hardened runtime and verifies its complete bundle signature before processing
events. Local mode intentionally does not create a DMG.

Public Developer ID distribution is fail-closed. It requires a Developer ID
Application identity and a `notarytool` Keychain profile:

```sh
AGENTBELL_DISTRIBUTION_MODE=developer-id \
AGENTBELL_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
AGENTBELL_NOTARY_PROFILE="agentbell-notary" \
/bin/zsh Scripts/build-dmg.sh release
```

The build signs, notarizes, staples, mounts, and verifies the exact DMG and
app. The DMG is written to `outputs/` with a SHA-256 manifest.

If an Apple Developer Program membership is unavailable, AgentBell supports
a free/ad-hoc distribution mode. macOS cannot verify the publisher or notarize
that build. The mode therefore requires a separate long-lived release key and
produces a documented DMG plus a detached signature. See
[SECURITY.md](SECURITY.md) for key creation, verification, and the limits of
this fallback.

The current release is 1.3.0 RC (build 29). AgentBell intentionally has no
network-based automatic updater; releases are replaced as app bundles so the
runtime remains dependency-free and offline.

The ImageGen-created minimalist icon lives at `Resources/AppIcon.png`. The
build script converts it into the native multi-resolution `AppIcon.icns`
bundled with the application. Dashboard provider icons are bundled vector
SVGs. The Codex mark is sourced from the current Codex vector listing on
DBLogo and remains an OpenAI trademark. The Claude symbol is the CC0 vector
published on Wikimedia Commons from Anthropic's mark.

## First run

1. Open `AgentBell.app`.
2. Allow notifications when macOS asks. Accessibility is optional and is
   never requested automatically; grant it manually in System Settings only
   if you want best-effort window matching for hosts without stable IDs.
3. Click the menu-bar bell, open Settings → Integration, then choose
   **Install Integration**.
4. In Codex, open `/hooks` once and approve the new non-managed hooks.

Open Settings → Testing to exercise the complete local notification path.
Testing includes a generic alert, every supported Codex and Claude Code
surface, and an all-apps action. Every test also creates a non-navigable
dashboard entry. If macOS accepts an alert but no banner appears, turn off
Focus or allow AgentBell in the active Focus mode.

AgentBell safely merges its entries into `~/.codex/hooks.json` and
`~/.claude/settings.json`, preserving unrelated configuration and creating
timestamped backups. The bundled VS Code extension is installed only by the
Install Integration action in Settings → Integration. That section also
shows the health of each installed provider hook and contains Repair
Integration.

Codex and Claude Code approval dialogs are observed through `PermissionRequest`
hooks and appear as **Needs attention**. Codex approval alerts are emitted only
when the effective reviewer is the user; Auto/Approve for me and Full Access
are suppressed. Input pickers are observed through narrowly matched
`PreToolUse` hooks. Approval previews show a sanitized tool
name and action; question previews retain only the first question, never its
choices or selected answers.

When first focusing a Ghostty session, macOS may separately ask whether
AgentBell can control Ghostty. That Automation permission lets AgentBell
capture and focus Ghostty's stable terminal ID; it is distinct from
Accessibility permission.

Open the dashboard's gear button for Settings. General contains launch at
login, quit confirmation, and dashboard-history retention. Terminal and test
items are removed after 30 minutes by default; cleanup can be disabled or set
from 1 minute through 7 days. Active work and unresolved Needs attention
items are never removed automatically.

Notifications contains the privacy switch and controls for Codex Desktop,
Codex CLI, Codex VS Code, ChatGPT Desktop, Claude Desktop, Claude Code CLI,
and Claude Code VS Code. Disabling a surface suppresses its alerts while
retaining its local session history and navigation. ChatGPT Desktop defaults
to a 30-second minimum task duration; Claude Desktop defaults to 0 seconds
(always). Both thresholds are editable from 0 through 3,600 seconds. Info
contains the installed version, privacy summary, and **Uninstall AgentBell…**
action.

Phone contains optional ntfy delivery. AgentBell uses the hosted `ntfy.sh`
service; it does not launch a local server or background ntfy process.
On first launch, AgentBell generates a separate private topic using 256 bits
from macOS's cryptographically secure random generator. **Connect Phone…**
shows an explicit QR code for the private HTTPS topic so the user can open it
on the intended iOS or Android device, subscribe in ntfy, and allow phone
notifications. **Test Phone Alert** then verifies actual receipt and adds a
matching entry to the dashboard; a successful publish alone is not presented
as proof that a phone subscribed. AgentBell makes no network request while
Phone alerts are disabled. By default, phone
payloads contain only the app surface and generic state. The optional details
switch adds the sanitized task title and preview. Phone payloads never contain
full prompts, transcripts, session IDs, working directories, file contents,
or navigation metadata.

### Secure topic design

- Topics are generated locally as `agentbell-` plus 43 unpadded base64url
  characters: 256 bits of CSPRNG entropy in 53 total characters, within
  ntfy's 64-character topic limit.
- AgentBell does not query ntfy to ask whether a generated topic exists.
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
- If secure randomness or Keychain access fails, AgentBell does not create an
  insecure fallback topic and phone publishing fails closed.

Settings → Info contains a confirmed **Reset All Settings…** action. It
returns notification, privacy, timer, phone, quit, and login choices to their
defaults, removes the ntfy token, and rotates the private topic. Integration
hooks and dashboard history remain intact. Since rotation invalidates the old
phone subscription, AgentBell explicitly directs the user through Connect
Phone again.

On public `ntfy.sh`, an unprotected topic name effectively acts as the shared
secret because anonymous read and write access are enabled. The 256-bit topic
makes guessing or accidental collision computationally infeasible, but it is
not a server-side reservation and absolute global uniqueness cannot be
guaranteed. For enforceable read/write authorization, reserve and protect the
topic in ntfy or use an authenticated self-hosted server with deny-by-default
ACLs.

Protected ntfy topics can use an optional publish access token. AgentBell
stores that token as a device-only generic-password item in macOS Keychain,
loads it only while publishing, and sends it only in the
`Authorization: Bearer …` header. The token is never stored in UserDefaults,
the durable outbox, URLs, hook configuration, process arguments, or logs.
Failed phone deliveries use bounded backoff and are discarded after eight
attempts or 24 hours.

Native task titles and previews are also off by default. Enable **Show
sensitive titles and previews** in Settings → Notifications to see sanitized
titles, questions, commands, and filenames while using the Mac. The setting
has an in-app privacy warning because macOS notifications may appear on a
lock screen or shared display. Detailed preview length is configurable from
10 through 120 characters, with 50 as the default. With details off, the
dashboard and native alerts use generic state descriptions instead of an
empty “No preview yet” placeholder. AgentBell sends generic native content
whenever the screen is locked and removes already-delivered detailed AgentBell
notifications when it observes a lock. For defense in depth, set System
Settings → Notifications → Show previews to **When Unlocked**; macOS owns that
system policy and apps cannot change it.

## Privacy and behavior

### What leaves the Mac

Nothing leaves the Mac while Phone alerts are off. When they are on, AgentBell
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
- AgentBell does not read source files in a repository. Title resolution reads
  only bounded title metadata from Codex's session index and Claude Code's
  local session records; unrelated transcript entries are ignored and never
  persisted.
- A central sanitizer strips controls, bidirectional overrides, common token
  and credential shapes, URL credentials, home-directory usernames, and email
  addresses from outbound detail text.
- Native Notification Center routing metadata contains only an opaque hash,
  never a raw provider or session identifier.
- Runtime files use user-only permissions under
  `~/Library/Application Support/AgentBell`.
- The ntfy topic and optional token are stored device-only in macOS Keychain.
  Neither secret is persisted in UserDefaults or the retry outbox.
- Only PIDs learned from hook events are checked for liveness; AgentBell does
  not continuously scan the process table. The event queue has a 60-second
  recovery fallback, and PID checks run every 15 seconds only while a tracked
  agent is active.
- Queue batches are claimed before processing and replayed after a crash.
  Persisted event deduplication prevents a replay from producing a second
  alert.
- AgentBell contains no third-party runtime dependencies and emits no raw hook,
  request-body, token, path, or transcript logs.
- Claude `StopFailure` events such as rate limits and provider errors are
  reported as Failed. Explicit Codex network/rate-limit stops and unexpected
  tracked-process exits are also reported as Failed.
- Sleep pauses process liveness checks. After wake, AgentBell clears stale
  suspicions and requires fresh failed birth-identity checks before reporting
  a process that disappeared while the Mac slept.
- Finished rows and alerts include the elapsed turn duration when a matching
  start event was observed, for example `Finished (18m 42s)`.
- ChatGPT Desktop and Claude Desktop are identified from the captured host
  process rather than guessed from the project. The duration threshold affects
  both native and optional phone alerts; shorter work remains visible in local
  dashboard history.
- Dashboard history consolidates session IDs belonging to the same exact
  provider process birth and hides lifecycle-only start/end records, avoiding
  duplicate task cards without conflating a reused PID.
- Phone deliveries are persisted before sending, retried with bounded backoff
  after offline, DNS, TLS, rate-limit, and server failures, and use a stable
  opaque ntfy sequence identifier so ambiguous retries update one phone alert.
- A single-instance lock prevents two AgentBell processes from concurrently
  changing the queue or dashboard state.
- A live session is focused, never resumed into a second process.
- Swipe left on a dashboard session and press **Clear** to remove that row and
  its matching delivered alerts without ending the underlying agent session.
  The row tilts and falls backward before leaving the dashboard.
- The header **Clear** button applies the same fall-back animation to every
  visible session before clearing the complete history.
- Completed, failed, ended, and synthetic test rows expire after 30 minutes by
  default. The interval and automatic cleanup switch are in Settings →
  General; active and unresolved attention rows do not expire.
- Quit is visually destructive and asks for confirmation by default. The
  confirmation can be disabled in Settings → General.
- The dashboard footer shows the installed version and build number.
- Test-alert and integration-repair result messages disappear automatically
  after approximately five seconds.
- Terminal.app sessions are matched to their exact tab by TTY. Ghostty
  sessions are matched by the stable terminal ID captured at a hook event.
  If either identifier is unavailable, AgentBell falls back to activating the
  original app and matching its window.

## Uninstall

Open Settings → Info and choose **Uninstall AgentBell…**. It removes only
AgentBell-owned hooks, uninstalls the VS Code companion, unregisters login
startup, clears AgentBell state, and moves the app to Trash. Configuration
backups are kept.
