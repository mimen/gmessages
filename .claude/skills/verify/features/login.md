# Login

A user starts logging in to Google Messages from the management room. The only advertised flow is Google account (cookies, then emoji pairing on the phone); QR pairing is compiled in but not offered.

## Sub-features

- `login-google-prompt` `login` (or `login google`) asks for cookies and gives the Google login URL.
- `login-pending` a second `login` while one is open is refused.
- `login-cancel` `cancel` ends the pending login.
- `login-qr-hidden` `login qr` is rejected as an invalid flow.
- `login-list` `list-logins` and provisioning `whoami` report no logins and the `google` flow.
- `login-complete` submitting cookies and pairing: blocked.

## How to get to it (user POV)

- Type `login` in the management room. Provisioning clients use `GET /_matrix/provision/v3/login/flows` and `POST /_matrix/provision/v3/login/start/google`.

## Driving it with verify.sh

Preconditions:

- Management room exists and no login is in progress.

- **Cookie prompt.** Run `$V say login`. The bot replies `Enter a JSON object with your cookies, or a cURL command copied from browser devtools.` and `Login URL: <https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config>`.
- **Pending.** Run `$V say login google`. The bot replies `You already have an ongoing login. You can use !gm cancel to cancel it.`
- **Cancel.** Run `$V say cancel`. The bot replies `Login cancelled.`
- **QR hidden.** Run `$V say login qr`. The bot replies `Invalid login flow qr. Available options:` and lists only `google`.
- **No logins.** Run `$V say list-logins` and `$V whoami`. The bot replies `You're not logged in`; `logins` is `[]` and `login_flows` is `["google"]`.

## Gotchas

- While the cookie prompt is open, the bridge would submit any unrecognised message to Google. `say` refuses `frobnicate` in that state and accepts no free text; always end with `cancel`.
- Do not paste real Google cookies into this run. A successful submission pairs against the account's phone and replaces its current Google Messages web session.
- Completing a login needs a phone running Google Messages with account pairing on, signed in to a test Google account. Report `login-complete` as blocked on that.
- The QR flow is commented out of `LoginFlows` in `pkg/connector/login.go`. If it comes back, `login` with no argument will ask for a flow instead of prompting for cookies; update this file.
