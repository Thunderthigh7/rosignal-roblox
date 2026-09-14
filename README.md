# RoSignal Roblox source

Public Roblox-side source for [RoSignal](https://rosignal.app).

This repository exists so Roblox developers can inspect the code that runs in Studio or is inserted into their experience.

## What is public here

- `plugin/RoSignalPlugin.server.lua` — the Studio plugin source used to pair a place, install/update the RoSignal runtime, repair setup, and export place geometry for the analytics map.
- `runtime/plugin-module.server.ts` — the source generator used by RoSignal to produce the Luau scripts inserted into `ServerScriptService` during pairing.
- `runtime/ingest.ts` — the public constants/defaults referenced by the runtime generator.

The generated scripts are:

- `ServerScriptService/RoSignal` — the runtime module.
- `ServerScriptService/RoSignalHandlers` — the developer-owned entry point.
- `RoSignalHandlers/RoSignalDemo` — optional starter UI used during first-run testing.
- `ServerScriptService/RoSignalSettings` — developer-owned analytics/map settings.

## What the plugin does

The plugin:

1. connects only to `https://rosignal.app`;
2. exchanges a one-time pairing code for a game-specific key and the latest script payload;
3. installs the runtime and starter scripts;
4. preserves developer-owned handler/settings files after they are created;
5. stores the paired game key in Roblox Studio plugin settings for that place;
6. can export visible place geometry to RoSignal for the Analytics map.

The game-specific key is created during pairing. No real customer game key or credential is committed to this repository.

## What remains private

RoSignal's hosted web application and backend remain proprietary. That includes the dashboard, automation engine, database/server logic, billing, internal admin tooling, abuse prevention, and infrastructure.

Publishing this repository is about auditability of the Roblox-side code, not publishing the entire RoSignal service.

## Source status

The files in this repository are intended to mirror the Roblox-side source used by the live RoSignal product. Game-specific values such as keys and game IDs are injected at pairing time and are not part of the public source.

## Security

If you believe you found a security problem, please do not post credentials, game keys, or private account information in a public issue. See [SECURITY.md](SECURITY.md).

## License

No open-source license is currently granted. The source is published for transparency and security review. All rights are reserved unless stated otherwise in writing.
