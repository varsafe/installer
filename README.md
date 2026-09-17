# varsafe installer

This is the script behind:

```sh
curl -fsSL https://varsafe.dev/install.sh | bash
```

It is published here so that the code you are about to pipe into your shell can be read, diffed and
tested before you run it — and so that its refusal paths are tested in public, on the machines people
actually use, rather than only on a build server.

The varsafe product itself is closed source. This repository holds the installer and its test suite,
nothing else. `install.sh` is mirrored one-way from the private source of truth, so a change lands
here only after it has passed review there.

## What the installer guarantees

- **It verifies the release before installing it.** Every release publishes a manifest
  (`release.json`) signed with varsafe's Ed25519 release key, in two encodings: an OpenSSH signature
  (`release.json.sshsig`, checked with `ssh-keygen -Y verify`) and a raw signature
  (`release.json.sig`, checked with `openssl pkeyutl`). The installer verifies the manifest, then
  checks the downloaded binary's SHA-256 against it. The public key is pinned in `install.sh` in both
  encodings, and the test suite asserts they are the same 32 bytes.
- **It refuses rather than guesses.** A checksum mismatch, a signature that does not verify, a
  truncated download, an unsupported architecture, a directory it cannot write — each is a refusal
  with the reason, and nothing is installed.
- **It tells the truth about what it cannot do.** On a machine with no verifier it can use — stock
  macOS ships a LibreSSL that cannot check Ed25519 at all — it says which tools it found and why they
  cannot verify. It never reports a verification it did not perform, and it never calls a release
  tampered with unless a verifier actually rejected it.

## Installing a specific version

```sh
VARSAFE_VERSION=7.2.32 curl -fsSL https://varsafe.dev/install.sh | bash
```

Useful for pinning in CI, or for putting a known-good version back. The value is validated as a
version before it is used, so it cannot walk out of the release path.

Choose the directory with `VARSAFE_INSTALL_DIR` (default `~/.varsafe/bin`).

## Running the tests

```sh
bash scripts/test-install-sh.sh
```

No network and no real install: the suite drives the installer's own functions against a fake CDN,
with real Ed25519 fixtures, and builds a PATH holding exactly the tools a given machine has — so it
can ask what happens on a host whose openssl cannot verify, or whose `ssh-keygen` predates SSHSIG.

A case a host genuinely cannot exercise (no bash-free POSIX shell for the `curl | sh` re-exec path,
no openssl that can sign Ed25519 for the fixtures) reports as `skip` with the reason rather than as a
pass. CI runs the suite on macOS (arm64 and Intel) here, and on Debian, Ubuntu 20.04, Alpine and
Fedora in the private pipeline.

The macOS workflow here is a **canary, not a release gate**: it runs in a public repository and it
executes whatever varsafe.dev currently serves, so its verdict cannot be evidence that a release is
authentic. Whether a release may be promoted is decided in varsafe's private pipeline, which
installs the artifacts it just built using the installer from that tag and verifies them against the
signing key compiled into the CLI. What this workflow is good for is noticing that an install users
can reach broke on macOS — including when nothing of ours changed and an OS update moved OpenSSH or
LibreSSL underneath it.

## Reporting a problem

Security issues: security@varsafe.dev. Everything else: https://docs.varsafe.dev.
