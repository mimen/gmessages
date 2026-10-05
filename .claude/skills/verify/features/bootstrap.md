# Bootstrap

An operator generates a config and an appservice registration from the binary, registers it with a homeserver, and starts the bridge.

## Sub-features

- `boot-example-config` writes the example config with `-e`.
- `boot-registration` writes `registration.yaml` with `-g`.
- `boot-version` reports the build with `--version` and the `version` command.
- `boot-start` connects to the homeserver and logs `Bridge started`.

## How to get to it (user POV)

- `mautrix-gmessages -e -c config.yaml`, then `mautrix-gmessages -g -c config.yaml -r registration.yaml`, then `mautrix-gmessages -c config.yaml`.

## Driving it with verify.sh

Preconditions:

- Docker running, an unused `GMV_RUN_ID`, and a fresh evidence path. `up` runs all three CLI steps.

- **Generate and start.** Run `GMV_EVIDENCE=<fresh dir> $V up`. The evidence dir gets `up.log`, listing the run dir, build, config, the Synapse container ID, test identity, `bridge: pid <n> start '<time>' argv 'gmessages:bridge@<id> -c ...'`, and a healthy doctor.
- **Health.** Run `$V doctor | tee doctor.log`. Every line is `ok`, including `binary --version carries <sha8>`, `bridge listens only on 127.0.0.1:<port>`, and `synapse running, published only on 127.0.0.1:<port>`.
- **Version.** Run `$V say version`. The bot replies `mautrix-gmessages v26.09+dev.<sha8>` with the checkout SHA.

## Gotchas

- A failed `up` leaves `failed-startup/` in the evidence dir and tears down what it started. Read its `up.log` and `bridge.stdout.log` before retrying with a new run ID.
- `up` fails closed if the example config's keys moved and the edits did not apply; read the `FAIL` line rather than editing config by hand.
- Synapse must read the registration from `/data/gmv.yaml` as a second `--config-path`. Rewriting `homeserver.yaml` in place on a Docker Desktop bind mount served a truncated file.
