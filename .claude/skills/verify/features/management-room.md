# Management room

A Matrix user invites the bridge bot to a DM, which becomes their management room, and types bridge commands there.

## Sub-features

- `mgmt-invite` the bot joins, greets, and marks the room as the management room.
- `mgmt-help` lists command sections.
- `mgmt-unknown` an unknown command gets an error reply, not silence.

## How to get to it (user POV)

- Start a DM with `@gmessagesbot:<server>` from any Matrix client and type commands without the `!gm` prefix.

## Driving it with verify.sh

Preconditions:

- Doctor healthy; no `ROOM_ID` in `/private/tmp/gmv-<id>/state.env` yet.

- **Invite.** Run `$V say help`. The transcript first shows `USER invites @gmessagesbot` then `This room has been marked as your management room.`
- **Help.** The same call prints `This is your management room: prefixing commands with !gm is not required.` and the `General`, `Authentication`, and `Starting and managing chats` sections.
- **Unknown command.** Run `$V say frobnicate`. The bot replies `Unknown command, use the help command for help.`
- **Stored room.** Run `$V whoami`. `management_room` equals `ROOM_ID` from `/private/tmp/gmv-<id>/state.env`.

## Gotchas

- Only a two-member room becomes the management room. Inviting the bot into a larger room does not.
- Users outside `gmv.localhost` only have `relay` permission and cannot run commands.
