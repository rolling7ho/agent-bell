# AgentBell security

## Security boundary

AgentBell is a local macOS application. No client-side measure can make its
compiled implementation impossible to inspect or make an untrusted publisher
indistinguishable from the legitimate publisher.

AgentBell therefore uses layered controls:

- signed bundle integrity checks before the app or hook processes data;
- hardened runtime for every packaged build, including ad-hoc builds;
- Developer ID signing and notarization when Apple credentials are available;
- an explicit, visibly untrusted free-distribution mode with detached
  signatures and SHA-256 manifests;
- no automatic updater or third-party runtime packages;
- a minimal, allowlisted and minified VS Code companion package;
- device-only Keychain storage for ntfy topics and tokens;
- 256-bit random ntfy topics, with automatic rotation of weaker legacy values;
- bounded, validated hook inputs and privacy-preserving notification payloads.

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
AGENTBELL_DISTRIBUTION_MODE=developer-id \
AGENTBELL_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
AGENTBELL_NOTARY_PROFILE="agentbell-notary" \
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
mode is therefore deliberately labeled untrusted by macOS.

Create a long-lived detached-signing key outside the source tree:

```sh
/bin/mkdir -p "$HOME/.agentbell-signing"
/bin/chmod 700 "$HOME/.agentbell-signing"
/bin/zsh Scripts/create-free-release-key.sh \
  "$HOME/.agentbell-signing/release-private.pem" \
  "$HOME/.agentbell-signing/release-public.pem"
```

Then build:

```sh
AGENTBELL_DISTRIBUTION_MODE=adhoc \
AGENTBELL_RELEASE_PRIVATE_KEY="$HOME/.agentbell-signing/release-private.pem" \
/bin/zsh Scripts/build-dmg.sh release
```

The output filename contains `UNTRUSTED-adhoc`. The output directory also
contains a SHA-256 manifest, a detached signature, the public key, and the
public-key fingerprint.

Publish the public-key fingerprint through at least one independent trusted
channel. A public key downloaded from the same compromised location as the
DMG does not establish identity.

Recipients verify before opening:

```sh
/bin/zsh Scripts/verify-download.sh \
  AgentBell-1.3.0-build28-arm64-UNTRUSTED-adhoc.dmg \
  AgentBell-1.3.0-build28-arm64-UNTRUSTED-adhoc.dmg.sha256 \
  AgentBell-1.3.0-build28-arm64-UNTRUSTED-adhoc.dmg.sha256.sig \
  AgentBell-release-public.pem
```

Do not instruct users to disable Gatekeeper globally or remove quarantine
attributes. Detached signatures protect users only after they have obtained
and pinned the legitimate public key.

## ntfy topics

Every accepted AgentBell-generated topic is `agentbell-` followed by 64
lowercase hexadecimal characters derived from 256 bits supplied by
`SecRandomCopyBytes`. Stored or legacy topics that do not have this exact
format are deleted and replaced.

Collision is computationally negligible but not mathematically impossible,
and an unreserved public `ntfy.sh` topic is not an authorization boundary.
The topic acts as a bearer secret. Anyone who learns it may be able to
subscribe or publish.

For enforceable access control, reserve and protect the random topic in ntfy
or use an authenticated self-hosted server with deny-by-default ACLs. A
publish token does not automatically make an otherwise public, unreserved
topic private.

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
