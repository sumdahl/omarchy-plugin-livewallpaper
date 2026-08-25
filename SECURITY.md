# Security

This plugin runs unsandboxed inside `omarchy-shell`, a Quickshell process that
lives for your whole login session. Anything that lands in
`~/.config/omarchy/plugins/io.github.sumdahl.livewallpaper/` and is loaded by the
shell runs with your user's full privileges. An update mechanism is therefore a
code-delivery channel, and it is designed here as one.

## How updating works

The plugin **detects** updates. It never applies them.

`bin/omarchy-live-update-check` runs every six hours and:

1. refuses unless `origin` still points at this repository;
2. asks the remote for **refs only** (`git ls-remote`) — no code is transferred;
3. finds the newest `vX.Y.Z` tag and requires **remote `HEAD` to equal that tag**;
4. requires the tag's version to be newer than the installed `manifest.json`;
5. fetches the tag object and verifies its **SSH signature** locally against
   `.github/allowed_signers`;
6. requires the signing key to match the fingerprint this installation recorded
   the first time it verified a release.

Any failure means no update is offered. The check never checks anything out and
never executes a byte that came from the remote.

Applying is `omarchy plugin update`, Omarchy's own first-party command, launched
in a visible terminal. It prints the complete diff, waits for you to agree,
refuses anything that is not a fast-forward, and rolls back if the result fails
validation. **There is no code path in this plugin that installs an update
without showing you that diff first**, and there will not be one.

### Step 3 is the part that matters

`omarchy plugin update` fast-forwards to remote `HEAD`, not to a tag. Verifying a
signature on a tag and then fast-forwarding to `HEAD` would prove nothing if the
branch had moved past it. Requiring `HEAD == newest signed tag` means the commit
that lands is the commit whose signature was checked.

It also means a push to `main` reaches nobody until a release is deliberately cut
and signed.

### Key pinning is trust-on-first-use

`.github/allowed_signers` ships inside this repository, so anyone who controls
the repository controls that file too. The first release that verifies records
the key's fingerprint in `~/.local/state/omarchy-live/signer.pin`, and any later
change is refused rather than silently accepted — the SSH host-key model, with
the same honest limitation: **the first key an installation sees is trusted
blindly.**

If a key rotation is genuine, delete that file after confirming the new key.

## What this protects against

- an accidental or stray push reaching users (`HEAD` must equal a signed tag)
- a published release being quietly moved to different code (tags are immutable
  by ruleset)
- history rewrites and force-pushes (`--ff-only`, plus branch rules)
- an unreviewed change landing on `main` (pull request + required status check)
- the signing key being swapped underneath you (first-use pin)
- anything at all being installed without a diff you read and a yes you gave

## What this does not protect against

**A compromise of the maintainer's GitHub account or laptop.** An attacker in
that position cuts an ordinary, correctly signed release, and every control above
passes. Branch protection defends a repository against other people and against
mistakes; it is not a defence against its owner being compromised.

**Malicious code that is syntactically valid.** Neither this project's CI nor
`omarchy-plugin-validate` inspects code for intent — Omarchy's validation is a
manifest-schema check. Nothing here should be read as "this code has been
audited".

The real protection available to you as a user is the last one in the list above:
the diff is shown, and nothing happens until you agree. Read it.

## Reporting

Open a GitHub issue, or for something you would rather not post publicly, use
GitHub's private vulnerability reporting on this repository.
