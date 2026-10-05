# mautrix-gmessages verification map

The maintained list of user-facing bridge features and how to prove each with [verify.sh](../scripts/verify.sh). Read this before a run, then use the matching file as the recipe.

## Baseline preconditions

- Docker Desktop running; `matrixdotorg/synapse` image available.
- `GMV_RUN_ID` is exported, `$V up` succeeded from this checkout, and `$V doctor` printed `doctor: healthy`.
- The test user is `@gmvtester:gmv.localhost`; the bot is `@gmessagesbot:gmv.localhost`.
- Never drive a bridge this run did not start.

## Driving conventions

- Every command below is literal. `$V` is `.claude/skills/verify/scripts/verify.sh`.
- One run serves all features, in the order listed. The first `say` creates the management room.
- `$V say` accepts only the commands these files use. Capture with `$V evidence` before `$V down`.

## Proof and skip reporting

- Pair each command with the bot's reply in `transcript.txt`, and confirm state through `whoami` or `store.txt`.
- A feature that needs a paired phone is `blocked`, with that prerequisite named. Do not report it as verified through a different path.

## Features

| File | Read when |
|---|---|
| [bootstrap.md](bootstrap.md) | Proving config and registration generation, version, and startup against a homeserver |
| [management-room.md](management-room.md) | Proving the bot DM, `help`, `version`, and command routing |
| [login.md](login.md) | Proving the Google cookie prompt, pending-login refusal, `cancel`, the hidden QR flow, and `list-logins` |
| [persistence.md](persistence.md) | Proving the management room and login state survive a bridge restart |
| [messaging.md](messaging.md) | Chats, portals, sending, reactions, receipts: blocked without a test phone |
