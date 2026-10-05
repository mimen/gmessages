---
name: verify
description: Drive the mautrix-gmessages bridge built from this checkout the way a Matrix user does, against a disposable Synapse homeserver and test account, and capture proof. Use when a change to cmd/, pkg/connector, or pkg/libgm needs to be shown working in the real bridge (startup, management room, login flows, stored state), not just compiled or unit-tested.
---

# Verify mautrix-gmessages

The user surface is a Matrix appservice: a user DMs `@gmessagesbot` and types commands in that management room, and clients call the provisioning API.

[scripts/verify.sh](scripts/verify.sh) owns one isolated run: a bridge binary built from this checkout, a labelled Synapse container, a SQLite store, and a throwaway Matrix user `@gmvtester:gmv.localhost`. Nothing touches a resident bridge, the user's Beeper, or a real Google account.

## Launch

```sh
V=.claude/skills/verify/scripts/verify.sh
export GMV_RUN_ID=<id>              # required on every call; ^[a-z0-9][a-z0-9-]{0,31}$
GMV_EVIDENCE=/Users/mimen/Documents/verification-proofs/<wave>/gmessages/<attempt> $V up
```

- **Needs** Docker Desktop running and the `matrixdotorg/synapse` image (pulled on first use).
- **Scratch.** `up` creates `/private/tmp/gmv-<id>` fresh with mode 700 and an `owner` marker naming the run ID and this checkout. It refuses an existing path or symlink. Every later command checks that marker, so a run is only usable from the checkout that created it.
- **Evidence dir.** `GMV_EVIDENCE` must be a fresh absolute path whose parent exists without symlinks, outside the checkout and `/tmp`. `up` creates it and never reuses it.
- **Build.** `go build -tags goolm` into the scratch dir; this Mac has no libolm, so the default build fails here (CI builds it on Linux, see Gates).
- **Config.** Written by the binary's own `-e`. Only homeserver, appservice port and `hostname: 127.0.0.1`, SQLite URI, permissions and log path are edited. The registration comes from `-g`.
- **Homeserver.** Synapse published only on `127.0.0.1:<port>`, labelled `gmv.run` and `gmv.checkout`, loading the registration through a second `--config-path`, plus the test user. Its password is never stored; only its token sits in the private `state.env`.
- **Bridge.** Started with argv `gmessages:bridge@<id> -c ... -r ... -n`. PID, start time and argv are recorded the moment it spawns; ready when `Bridge started` appears in `bridge.stdout.log`.
- **Failure.** If any step fails, `up` captures `failed-startup/` into the evidence dir, then runs `down`, which stops only what it recorded.

## Doctor

`$V doctor` is read-only and exits non-zero on any failed line. `say`, `whoami`, `restart` and `evidence` run it first and refuse on failure. It checks:

- the owner marker binds the run to this checkout, and the checkout fingerprint (HEAD, tracked diff, untracked files including this helper) is unchanged since `up`;
- the binary hash is unchanged and `--version` carries the source SHA;
- the recorded bridge PID has the recorded start time, full argv, cwd the scratch dir, and listens only on `127.0.0.1:<bridge port>`;
- the Synapse container has the recorded ID, name, run and checkout labels, and is published only on `127.0.0.1:<port>`;
- the token belongs to `@gmvtester:gmv.localhost`, provisioning `whoami` names the bot, and the stored management room matches.

## Drive

- **Management room commands.** `$V say <command>` sends one of the mapped commands as the test user and prints every bot reply until 4 s of quiet. Allowed: `help`, `version`, `frobnicate`, `login`, `login google`, `login qr`, `cancel`, `list-logins`, `start-chat +15555550100`. Anything else is refused before it reaches Matrix.
- **Login guard.** While a login prompt is open, the bridge treats any unrecognised message as cookies to submit to Google. The helper therefore refuses `frobnicate` until `cancel`, and has no way to send cookie text.
- **Provisioning view.** `$V whoami` prints `GET /_matrix/provision/v3/whoami` for the test user.
- **Restart on the same store.** `$V restart` stops the verified PID and starts the bridge again on the same config and database, then runs doctor.

The [feature map](features/README.md) has one recipe per feature. Run them in order on one run.

## Evidence

- **Capture.** `$V evidence` writes a new `capture-<HHMMSS>/` inside the run's evidence dir and refuses to overwrite one.
- **What it writes.** `transcript.txt` (each command with UTC time and every bot reply), `bridge.stdout.log` (every start of this run), `store.txt` (user row, login and portal counts read from SQLite read-only), `doctor.txt`, and `manifest.txt` (source SHA and fingerprint at `up` and now, binary, helper and SKILL.md hashes, Synapse container and image, ports, bridge PID, start and argv, dirty files). Test user token, provisioning secret and appservice tokens are redacted.
- **Also save** `whoami` and `restart` output with `tee` into the evidence dir.
- **Proof standard.** A proof pairs the command sent with the bot's reply and a second, read-only view of state (`whoami` or `store.txt`), ideally across a `restart`. `go test`, `--help`, or a grep is not a proof of a flow.
- **No UI.** The bridge has no screen of its own, so there is no video; the Matrix transcript is the user-visible record.

## Cleanup

`$V down` checks everything before stopping anything: the owner marker, the bridge PID's start time, argv and cwd, that no unrecorded `gmessages:bridge@<id>` process exists, and the container's ID and labels. On any mismatch it refuses and keeps the scratch dir. Then it stops the PID, removes the container, and deletes the scratch dir. Evidence lives outside it and survives; `ls` it after `down`.

## Gates

- **CI** (`.github/workflows/go.yml`) is pre-commit on Linux with libolm. Reproduce it in a disposable `golang:1.26` or `golang:1.27` container on a clone of the checkout: `apt-get install libolm-dev libolm3`, install `goimports`, `staticcheck` and `pre-commit`, then `pre-commit run --all-files`, `go build ./...` and `go test ./...`. Never install libolm on the host for this.
- **Local** `go vet`, `go test` and `staticcheck` with `-tags goolm` are a quick supplement, not a replacement.

## Limits

- **Google-side flows are unreachable here.** Pairing, chat sync, portals, sending, reactions and read receipts need a phone running Google Messages paired to this bridge. Doing that with the user's account would replace their existing web pairing, so report those flows as blocked with that prerequisite. A dedicated test phone and Google account would unblock them.
- **Stop at the cookie prompt.** `login` stays local until cookies are submitted. QR pairing is not advertised in this build, so `login qr` is rejected before any network call.
- **`pkg/libgm/gmtest`** is a developer REPL that reads `cookies.json` or `session.json` from its cwd and pairs or connects as that Google account. It has no safe disposable mode; do not run it with a copied session.
