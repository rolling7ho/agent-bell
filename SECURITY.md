# Turnring security

## Security boundary

Turnring is a local macOS application. No client-side measure can make its
compiled implementation impossible to inspect or make an untrusted publisher
indistinguishable from the legitimate publisher.

Turnring therefore uses layered controls:

- signed bundle integrity checks before the app or hook processes data;
- hardened runtime for every packaged build, including ad-hoc builds;
- Developer ID signing and notarization when Apple credentials are available;
- an explicit free-distribution mode with detached signatures, SHA-256
  manifests, and clear non-notarization disclosure;
- no automatic updater or third-party runtime packages;
- a minimal, allowlisted and minified VS Code companion package;
- a stable owner-only hook launcher that delegates to the current bundled
  helper, which still verifies the complete app signature before processing;
- device-only Keychain storage for ntfy topics and tokens;
- 256-bit random ntfy topics, with automatic rotation of weaker legacy values;
- bounded, validated hook inputs and privacy-preserving notification payloads.

Notification intent is stored only as a bounded allowlisted identifier such
as `question`, `plan_approval`, or `permission_request`. Human-facing copy is
generated locally. Question choices, answers, and plan contents are not
persisted. When Sensitive Previews is off, the app can identify the required
decision without displaying the underlying question, command, path, query, or
URL.

Code signing detects modification but does not hide code, guarantee that code
is vulnerability-free, or establish trust when the signature is ad hoc.

## Distribution modes

### Local development

```sh
/bin/zsh Scripts/build-app.sh release
```

This produces a hardened-runtime, ad-hoc-signed app for the current Mac. It
does not create a distributable DMG.

### Developer ID distribution

This is the only mode in which macOS can establish an Apple-trusted
third-party publisher identity outside the Mac App Store:

```sh
TURNRING_DISTRIBUTION_MODE=developer-id \
TURNRING_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
TURNRING_NOTARY_PROFILE="turnring-notary" \
/bin/zsh Scripts/build-dmg.sh release
```

The build fails unless the Developer ID identity and notarization profile are
available. It signs with hardened runtime and a secure timestamp, notarizes
and staples the app and DMG, mounts the DMG read-only, and verifies Gatekeeper,
the signatures, the tickets, the VSIX allowlist, and absence of source/debug
files.

### Free/ad-hoc distribution

Apple does not issue Developer ID Application certificates or accept
notarization submissions through a free Apple developer account. The fallback
mode is therefore clearly identified as not Apple-notarized.

Create a long-lived detached-signing key outside the source tree:

```sh
/bin/mkdir -p "$HOME/.turnring-signing"
/bin/chmod 700 "$HOME/.turnring-signing"
/bin/zsh Scripts/create-free-release-key.sh \
  "$HOME/.turnring-signing/release-private.pem" \
  "$HOME/.turnring-signing/release-public.pem"
```

Then build:

```sh
TURNRING_DISTRIBUTION_MODE=adhoc \
TURNRING_RELEASE_PRIVATE_KEY="$HOME/.turnring-signing/release-private.pem" \
/bin/zsh Scripts/build-dmg.sh release
```

The output directory contains the DMG, a SHA-256 manifest, a detached
signature, the public key, and the public-key fingerprint. The DMG includes a
plain-language notice that this free release is not Apple-notarized.

Publish the public-key fingerprint through at least one independent trusted
channel. A public key downloaded from the same compromised location as the
DMG does not establish identity.

Recipients verify before opening:

```sh
/bin/zsh Scripts/verify-download.sh \
  Turnring-1.3.0-build30-arm64.dmg \
  Turnring-1.3.0-build30-arm64.dmg.sha256 \
  Turnring-1.3.0-build30-arm64.dmg.sha256.sig \
  Turnring-release-public.pem
```

Do not instruct users to disable Gatekeeper globally or remove quarantine
attributes. Detached signatures protect users only after they have obtained
and pinned the legitimate public key.

## ntfy topics

Every accepted Turnring-generated topic is `turnring-` followed by 43
unpadded base64url characters derived from 256 bits supplied by
`SecRandomCopyBytes`. The resulting 53-character topic stays within ntfy's
64-character limit. Stored or legacy topics that do not have this exact
format are deleted and replaced.

Collision is computationally negligible but not mathematically impossible,
and an unreserved public `ntfy.sh` topic is not an authorization boundary.
The topic acts as a bearer secret. Anyone who learns it may be able to
subscribe or publish.

For enforceable access control, reserve and protect the random topic in ntfy
or use an authenticated self-hosted server with deny-by-default ACLs. A
publish token does not automatically make an otherwise public, unreserved
topic private.

### Topic display protection

The optional publish token uses secure entry and is not revealable. The random
ntfy topic is masked by default. Revealing it is limited to 60 seconds, marks
the containing window as unavailable for macOS window sharing, and masks the
topic again when the app or window loses focus, display configuration changes,
or supported capture software launches. This is defense in depth. macOS does
not provide applications with a universal advance callback for every
third-party capture path, so system capture exclusion is the primary
protection while the topic is revealed.

## Persistent hook launcher

Provider configuration uses an owner-only launcher at
`~/Library/Application Support/Turnring/TurnringHook`. On startup, Turnring
atomically refreshes that launcher to delegate to the current helper inside
the signed app bundle. App moves and updates therefore do not change the hook
command. The bundled helper still validates the complete enclosing app bundle
before accepting an event; the launcher is not treated as a replacement trust
boundary.

## Source protection

The working source should remain on a FileVault-protected volume in an
owner-only directory. Keep any Git remote private, require MFA and reviewed
changes, and keep signing keys outside the repository.

Release builds strip nonessential native symbols and package minified,
allowlisted JavaScript without source maps. These controls increase reverse-
engineering effort but cannot provide source confidentiality. Never embed
secrets or rely on obscurity for security.

## Reporting a vulnerability

Do not disclose credentials, private ntfy topics, user notification contents,
or exploit details in a public issue. Contact the distributor privately and
include the affected version, reproduction steps, and impact.
