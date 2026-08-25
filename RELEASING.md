# Releasing

Users resolve updates through **signed tags**, and the update check requires
`main` to point at the newest one. A release that is pushed but not tagged
reaches nobody; a tag that is not signed is refused by every installation.

So tagging is not paperwork here — it is the release.

> The discipline has already lapsed once: `v1.0.0` and `v1.0.1` were tagged,
> `v1.0.2` and `v1.1.0` were not. That is exactly the failure this checklist
> exists to prevent.

## One-time setup

```bash
# Sign with the personal key, and let git verify against the file in the repo.
git config user.signingkey ~/.ssh/id_personal.pub
git config gpg.format ssh
git config gpg.ssh.allowedSignersFile .github/allowed_signers
git config tag.gpgsign true
```

The key must be loaded in an agent, or signing fails with
`unable to sign the tag`:

```bash
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_personal
```

Register the same key on GitHub as a **signing key** (Settings → SSH and GPG
keys → New SSH key → key type *Signing Key*) so releases show as Verified there.
This is cosmetic: the plugin verifies locally against `.github/allowed_signers`,
not against GitHub's badge.

## Every release

1. Land the work on `main` through a pull request from `dev` or a `fix/*`
   branch. Direct pushes to `main` are blocked by ruleset.
2. Bump `version` in `manifest.json`. CI fails a tag whose version does not match.
3. Update the README if behaviour changed.
4. Tag and sign, at the commit that is now `main`:

   ```bash
   git tag -s v1.2.0 -m "v1.2.0 — short summary"
   git push origin main
   git push origin v1.2.0
   ```

5. Confirm what users will see:

   ```bash
   git verify-tag v1.2.0          # must report a good signature
   bin/omarchy-live-update-check  # from an older checkout: prints the version
   ```

`main` must end at the tagged commit. If you push anything afterwards without
tagging it, the check goes quiet until the next release — which is the intended
behaviour, not a bug.

## Never

- **Move or delete a published tag.** The ruleset blocks it; the reason is that
  every installation resolves updates through those tags, so a moved tag is a
  silent code swap on every machine.
- **Force-push `main`.** Blocked, and `omarchy plugin update` would refuse the
  result anyway.
- **Rotate the signing key casually.** Every existing installation has pinned the
  old fingerprint and will refuse the release until its user intervenes. If you
  must, say so loudly in the release notes and in the README.
