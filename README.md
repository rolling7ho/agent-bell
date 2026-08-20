# Turnring

Turnring is a lightweight native macOS menu-bar app that notifies you when
Codex or Claude Code finishes, fails, or needs your attention. It runs locally,
has no third-party runtime, and keeps phone alerts and sensitive previews
optional.

## Install

Turnring requires an Apple silicon Mac running macOS 13 or later.

1. Download the DMG from [GitHub Releases](https://github.com/rolling7ho/turnring/releases).
2. Open it and drag `Turnring.app` into Applications.
3. Open Turnring and complete the short menu-bar onboarding.
4. Allow notifications when macOS asks.

## If macOS denies the install

The free build is signed for integrity but is not Apple-notarized, so macOS may
block the first launch.

1. In Finder, open Applications.
2. Control-click `Turnring.app`, choose **Open**, then confirm **Open**.
3. If it is still blocked, open **System Settings > Privacy & Security**, find
   the Turnring message, and choose **Open Anyway**.

Do not disable Gatekeeper globally. If macOS reports that the app is damaged,
delete that copy and download it again from the official release page.

## Codex hooks

Turnring needs approved Codex hooks to know when to notify you.

- **Codex Desktop:** Open Settings, select **Hooks** under **Coding**, and
  approve all six hooks.
- **Codex CLI:** Run **`/hooks`** and approve all hooks.

## Performance

Turnring is a native Swift and AppKit app with no Electron or Node runtime. Its
background work is event-driven, so CPU usage should normally return to 0.0%
between short checks. Memory usage is typically in the tens of megabytes, not
the hundreds expected from a bundled browser runtime. Exact usage varies with
macOS, retained activity, and enabled integrations; Activity Monitor is the
authoritative measurement for your Mac.

## LICENSE

Turnring is available under the [Apache License 2.0](LICENSE).

Lines of Code: 17,565
