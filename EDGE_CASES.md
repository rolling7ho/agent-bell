# AgentBell 1.3 RC edge-case audit

This matrix records the intended behavior when an edge case occurs. “Handled”
means AgentBell remains safe and usable; it does not mean AgentBell can override
macOS policy, repair a provider that stopped emitting hooks, or determine
whether an ntfy phone subscription exists.

## Hooks and session state

| Edge case | Behavior | Evidence |
|---|---|---|
| Agent starts before AgentBell | The hook durably queues the next event and asks Launch Services to wake AgentBell. | Queue claim/replay tests; installed hook smoke test |
| Client has not reloaded repaired hooks | Existing agent work is unaffected; integration health remains incomplete until the client reloads. | Exact hook health tests |
| Codex hook still awaits trust | AgentBell reports setup guidance and never bypasses Codex trust. | Dashboard install flow |
| Claude user-level hook config changes | Hooks are merged into user settings; unrelated settings are preserved. | Configuration merge tests |
| Unknown, malformed, partial, or oversized hook payload | Payload is ignored; helper exits success without stdout and cannot change the agent decision. | Normalizer, queue, and helper smoke tests |
| Provider adds unrelated event fields | Only allowlisted fields are normalized; the remainder is discarded. | Normalizer/preview tests |
| Duplicate hook replay after app crash | Persisted dedupe keys suppress the second alert. | Queue replay and store restart tests |
| Late Stop or Claude idle event from an older turn | The newer working turn remains active. | Out-of-order turn tests |
| Claude idle and Stop for the same turn | State may update, but only one finished alert is emitted regardless of delay. | Idle/Stop coalescing test |
| Claude API request fails from a rate limit, authentication, billing, server, request, or output-limit error | `StopFailure` becomes one Failed event with a sanitized reason. | Abrupt-failure normalizer tests |
| Codex reports an explicit rate-limit, connection, authentication, or server error at Stop | The event becomes Failed; ordinary completion prose that merely mentions those terms remains Finished. | Narrow abrupt-stop classifier tests |
| Multiple approvals in one turn | Different sanitized actions each alert; exact replays do not. | Approval dedupe tests |
| Wall clock moves backward | New turns still advance monotonically; retries cannot be stranded. | Clock rollback tests |
| Same session ID from both providers | Provider-qualified keys keep them independent. | Provider collision tests |
| More than 50 active sessions | Every active/attention session remains tracked; the dashboard renders at most 50 rows. | Retention-limit tests |
| Session first appears at an approval | It enters Needs attention and is also liveness-tracked. | Liveness tracker tests |
| ChatGPT Desktop task finishes before its configured minimum | It remains in dashboard history but sends no native or phone alert. The default minimum is 30 seconds. | Desktop duration policy tests |
| Claude Desktop duration is left at 0 | Every supported Claude Desktop hook alert is eligible for delivery. | Zero-threshold policy test |
| Host bundle IDs overlap between Codex.app and ChatGPT.app | The captured host executable path distinguishes the ChatGPT-branded desktop app without changing CLI or VS Code labels. | Desktop host detection tests |
| Session ends without Stop | SessionEnd safely transitions to Ended without a false completion alert. | Event/state transition tests |
| CWD disappears after the hook | Event history remains valid; dead-session resume refuses the missing directory. | Deleted-CWD normalization and launcher validation tests |
| Conversation title missing or late | The alert retries local title lookup briefly, then uses “Untitled task”; prompt text is never substituted as a title. | Title resolver and prompt privacy tests |
| Title index/transcript is large or contains control text | Only bounded file windows and explicit title records are read; unsafe display controls are removed. | Large-index and safe-text tests |

## Processes and navigation

| Edge case | Behavior | Evidence |
|---|---|---|
| Agent crashes or is force-killed | Two consecutive failed birth-identity checks are required before one Failed alert. | Liveness and PID identity tests |
| Temporary `ps` failure | First failed observation is only suspicion and clears on the next live observation. | Liveness grace tests |
| Mac sleeps during an active task | Polling pauses; wake clears all pre-sleep suspicions and requires fresh checks. If the process disappeared, one Failed alert identifies the wake-related exit. | Sleep reset and liveness tests |
| PID is reused | PID plus process start identity prevents the replacement process being treated as the agent. | PID reuse test |
| Two AgentBell copies launch | The second process exits before opening mutable stores. | Single-instance lock test |
| Live session notification is clicked | AgentBell focuses; it never starts a second resume process while the recorded agent is alive. | Router liveness gate and argument tests |
| Delivered notification outlives cleared history | Click becomes a safe no-op. | Notification response lookup |
| VS Code companion missing or URI fails | Live routing activates VS Code; dead routing falls back to a safe Terminal resume. | Companion health gate and router fallback |
| VS Code request is stale, malformed, unsafe, or already consumed | The companion rejects it and deletes the one-shot file. | Companion validation code; stale-file cleanup tests |
| Terminal tab still exists | It is selected by exact TTY. | TTY-safe AppleScript route |
| Terminal/Ghostty identifier is missing or stale | AgentBell activates the owning app and uses a best-effort Accessibility window match. | Router fallback |
| Several terminals share one CWD | TTY, shell PID, cmux IDs, or Ghostty terminal ID take precedence over CWD. If no unique ID exists, AgentBell only activates the host rather than guessing a resume. | Routing order |
| cmux IDs are stale | Failed focus commands fall back to activating cmux; dead sessions fall back to Terminal if workspace creation fails. | Installed cmux CLI verification |
| Ghostty launch interface is unavailable | Dead-session launch falls back to Terminal. | Installed Ghostty CLI verification |
| Saved executable moved, has wrong provider name, or is non-executable | It is never launched; known local install paths are checked, otherwise the click reports unavailable. | Safe launcher tests |
| Session ID contains shell syntax | Validation rejects it; resume arguments are always passed separately. | Launcher argument tests |
| Resume script or focus request survives a crash | Private stale runtime files are removed on the next startup without following symlinks. | Runtime cleanup tests |

## Native and phone notifications

| Edge case | Behavior | Evidence |
|---|---|---|
| Notification permission denied | Dashboard/history still works; Test Alert points to System Settings. No repeated crash or blocking prompt occurs. | Native notification error path |
| Focus mode, notification summary, or macOS suppresses a banner | The alert is still submitted to Notification Center and retained in the dashboard; AgentBell cannot override system policy. | Foreground presentation and Test Alert path |
| The Mac is locked when an alert arrives | Native title and body are generic even if local details were enabled. If lock state cannot be determined, AgentBell fails closed to generic content. | Lock-state delivery policy |
| CoreGraphics does not expose the current session dictionary | AgentBell reads the native `IOConsoleLocked` registry property as a fallback, so an unlocked Mac is not permanently mistaken for a locked one. If neither native source is available, details still fail closed. | Screen lock monitor fallback |
| A detailed alert was delivered before the Mac locked | AgentBell removes delivered and pending detailed alerts when it observes the lock. macOS “Show previews: When Unlocked” remains the recommended system-level defense. | Lock observer and detail marker |
| Notification metadata is inspected | Only an opaque route hash and a detail-presence boolean are stored; raw session and provider identifiers are absent. | Opaque notification routing |
| AgentBell is frontmost | Delegate explicitly requests banner, list, and sound presentation. | `willPresent` implementation |
| Surface or event is disabled during title lookup | Preferences are rechecked immediately before delivery. | Delivery-time preference gate |
| Phone alerts are disabled | Outbox is cleared and no ntfy network request is made. | Preference reconciliation |
| Offline, DNS, TLS, HTTP 429, or 5xx failure | Alert remains in a private durable outbox and retries with bounded backoff. | Outbox and response validation tests |
| A phone delivery keeps failing | It is discarded after eight attempts or 24 hours instead of retrying forever. | Bounded retry and expiry tests |
| App quits or crashes during phone send | Unacknowledged delivery remains queued for the next launch. | Persist-before-send design and restart tests |
| Server accepted a request but response was lost | Stable opaque `sequence_id` makes the retry update one phone notification. | Sequence/request tests; ntfy publish API |
| Many phone failures accumulate | Outbox is capped at 200 newest deliveries and remains bounded on disk. | Outbox bound test |
| Corrupt, duplicate, malicious, or oversized outbox state | It is bounded, validated, deduplicated, or quarantined without a startup crash. | Outbox corruption tests |
| Phone has no matching subscription | Connect Phone presents the private topic as an explicit HTTPS QR setup link. ntfy may still accept a publish without a subscriber, so Test Phone Alert asks the user to confirm actual receipt instead of claiming the device is connected. | Device setup-link tests and Settings test flow |
| Fresh install needs a topic | First launch generates 256 CSPRNG bits locally and stores the resulting topic device-only in Keychain without contacting ntfy. | Secure-topic generation tests |
| Generated topic may already exist remotely | AgentBell does not perform a privacy-leaking, non-atomic availability probe. With 256 random bits, accidental collision is negligible; authenticated server ACLs are required for an enforceable reservation. | Secure-topic design |
| Upgrade has a valid topic in UserDefaults | It is migrated into Keychain and removed from defaults without changing the phone subscription. | Migration path |
| Private topic is guessed or shared | The topic is not logged, placed in arguments/hooks, or persisted in the retry outbox. It appears in a URL only in the user-invoked Connect Phone QR flow. Hosted ntfy remains a third party; AgentBell's uninstall flow deletes it. | Topic generation, setup-link, and outbox serialization tests |
| Topic is visible or copied during setup | Settings masks all but the final identifier characters. Copy Topic is explicit, and AgentBell clears its clipboard value after 60 seconds if it is still unchanged. | Phone settings flow |
| A protected ntfy topic needs authentication | The optional access token is stored device-only in Keychain, loaded only for publishing, and sent exclusively as a Bearer header. It is never placed in the outbox, URL, defaults, hooks, arguments, or logs. | Authorization request and unsafe-token tests |
| Keychain or secure randomness is unavailable | AgentBell creates no weak fallback topic; phone publishing fails with a generic error while local notifications and hooks continue normally. | Fail-closed topic path |
| Privacy details are off | Phone receives only app surface and generic state. | Phone message builder |
| Privacy details are on | Only sanitized, bounded title/preview is sent; no IDs, CWD, transcript, content, or routing metadata. | Request body and redaction tests |
| Native details are off | Dashboard cards and native alerts use a generic state title and description; stored detail is not rendered. | Dashboard privacy presentation test |
| Native preview length is customized | Detailed dashboard and native previews are Unicode-safe and clamped from 10 through 120 characters. | Dashboard privacy presentation and normalizer-bound tests |
| Unicode, control characters, or bidi overrides appear in text | Text remains character-safe, bounded, and display controls are removed. | Safe-text and truncation tests |

## Dashboard, settings, persistence, and installation

| Edge case | Behavior | Evidence |
|---|---|---|
| New event arrives during swipe-clear or Clear All animation | Conditional timestamp deletion preserves the newly updated row. | Conditional removal test |
| One Claude process rotates through multiple internal session IDs | The newest record is rendered as one task card using provider, PID, and process birth identity; clearing it clears the consolidated records. | Session presentation tests |
| Claude rotates its internal session ID before the terminal event | The terminal record inherits the active run start only from the exact same PID and process birth identity, so the title shows the real duration. | Rotated-session duration and PID-reuse tests |
| A terminal event arrives without any observed start | No duration is invented and `(0s)` is omitted from the title. Persisted legacy exact-zero durations are discarded on load. | Terminal-only and state-migration tests |
| Short-lived process emits only SessionStart and SessionEnd | The lifecycle record remains safe internally but does not create a blank dashboard card. | Lifecycle-only presentation test |
| Clear All includes history beyond visible rows | All captured snapshots are cleared, while changed snapshots survive. | Dashboard snapshot design |
| A card is swiped right | Move Down changes its dashboard order by one position without changing its state or timestamps. New task cards still appear above the manually ordered rows. | Dashboard ordering implementation |
| A terminal or synthetic test row reaches its retention limit | It is removed from history and its matching delivered notification/outbox record is removed. The default is 30 minutes. | History-retention policy tests |
| A time setting contains a decimal such as 2.5 minutes | Locale-aware decimal parsing preserves the value, clamps it to the setting's safe range, and stores it as a floating-point duration. Character-count settings remain integers. | Numeric settings implementation |
| Reset All Settings is pressed accidentally | A confirmation is required. Reset keeps hooks and history, clears the phone token/outbox, rotates the private topic, restores defaults, and tells the user to reconnect the phone. | Confirmed reset flow |
| A working or unresolved Needs attention row is older than the retention limit | Automatic cleanup leaves it intact until it reaches a terminal state or the user clears it. | History-retention policy tests |
| Automatic history cleanup is disabled | Terminal history is preserved subject to the existing bounded history limit. | Preference gate |
| A session changes while automatic cleanup is removing it | Conditional timestamp deletion preserves the newer state. | Conditional removal test |
| Quit confirmation is enabled | The red Quit button requires explicit confirmation; Cancel leaves the app running. | Confirmation-first flow |
| Quit confirmation is disabled | The red Quit button terminates immediately as requested by the saved preference. | General preference gate |
| Repeated phone tests | The previous settings task is cancelled before a new one begins. | Settings task lifecycle |
| Settings change while outbox has entries | Disabled state/surface/detail deliveries are discarded before retry. | Reconciliation logic |
| Light/dark appearance changes | Native colors are refreshed rather than frozen as stale layer colors. | Appearance update paths |
| Corrupt, duplicate, or oversized session state | Valid newest records load; unsafe records are skipped or the file is quarantined. | Session persistence tests |
| Concurrent hooks or session updates | File locks and in-process locks preserve complete independent records. | Concurrent queue/store tests |
| Install over empty or existing config | Both JSON files are validated first, unrelated hooks and Codex `notify` are preserved, and backups are created. | Configuration tests |
| Hook executable path contains spaces or quotes | A fixed provider command is POSIX-quoted without interpolation. | Shell-quote test |
| Second config write or companion install fails | Both config files roll back to their original bytes. | Transaction rollback test |
| Config is invalid, read-only, or oversized | Install stops without replacing it and reports an error. | Invalid/oversized/write failure tests |
| Repair is repeated | Owned hook groups are replaced idempotently, not duplicated. | Idempotent merge test |
| Integration health is incomplete | Settings → Integration shows the provider breakdown and the Install/Repair action; the dashboard remains focused on session history. | Integration settings flow |
| App update contains changed helper/extension | Clean bundle assembly removes stale build contents; Repair Integration points hooks to the installed helper and force-updates the companion. | Build script and installation smoke test |
| Login item needs macOS approval | Preference remains visible and the app reports the System Settings route; startup failure does not affect hooks. | `SMAppService` error path |
| Uninstall races a phone retry or title lookup | Delivery task is cancelled and all late state mutations are gated before support files are removed. | Uninstall gate |
| Uninstall is cancelled | Nothing changes. | Confirmation-first flow |
| Uninstall proceeds | Only owned hooks/companion/state/notifications/preferences/login item/app are removed; config backups remain. | Ownership and uninstall transaction tests |
| Moving the app without repairing hooks | Health check reports missing exact commands; Repair Integration rewrites only AgentBell-owned entries. | Exact command health tests |

## External limits

- macOS decides whether a banner is visually shown and whether login-item or
  Accessibility approval is granted.
- Codex and Claude Code must continue emitting their documented hooks; unknown
  schema is ignored so it cannot break agent work.
- ntfy delivery confirms server acceptance, not that a particular phone is
  online or subscribed.
- Exact focus depends on metadata exposed by the host. When it is absent,
  AgentBell uses a non-destructive activation fallback and does not invent a
  terminal identity.
