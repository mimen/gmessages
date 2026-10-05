# Messaging and portals

After login the bridge syncs recent chats into portal rooms and relays messages, media, replies, reactions, typing, read receipts, and deletions both ways (see [ROADMAP.md](../../../../ROADMAP.md)).

## Sub-features

- `msg-sync` initial chat sync creates portal rooms.
- `msg-inbound` a phone message appears in its portal.
- `msg-outbound` a Matrix message is sent from the phone.
- `msg-start-chat` `start-chat <phone>` and `resolve-identifier` open a DM portal.
- `msg-reactions-receipts` reactions, typing, and read receipts relay.

## How to get to it (user POV)

- Log in, then use the portal rooms the bridge creates, or `start-chat` in the management room.

## Driving it with verify.sh

Preconditions:

- A completed login (see [login.md](login.md)). Not available in this harness.

- **Blocked.** Run `$V say start-chat +15555550100`. The bot replies that the command requires login. Record every sub-feature as `blocked: needs a test phone paired to a test Google account`.

## Gotchas

- Any send, reaction, or receipt here reaches real people. Use only a dedicated test phone and contacts.
