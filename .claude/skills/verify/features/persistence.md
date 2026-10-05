# Persistence across restart

The bridge stores each user's management room and logins in its database, so a restart keeps them.

## Sub-features

- `persist-mgmt-room` the management room survives a restart.
- `persist-commands` commands work after restart without re-inviting the bot.

## How to get to it (user POV)

- Restart the bridge process; keep using the same DM.

## Driving it with verify.sh

Preconditions:

- Management room created by an earlier `say`.

- **Restart.** Run `$V restart`. It prints the new PID, start time and argv, then a healthy doctor.
- **Reread.** Run `$V whoami`. `management_room` still equals `ROOM_ID`.
- **Command after restart.** Run `$V say version`. The bot replies with the version and no fresh greeting.
- **Store.** Run `$V evidence` and read `store.txt` in the new `capture-*` dir. The `user` row for `@gmvtester:gmv.localhost` has the same `management_room`.

## Gotchas

- `restart` runs doctor first and refuses to signal a PID whose start time, argv or cwd changed. If it refuses, `down` refuses too; inspect the scratch dir before removing anything by hand.
