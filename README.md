# RoSignal Roblox source

Public Roblox-side source for [RoSignal](https://rosignal.app).

This repository exists so Roblox developers can inspect the code that runs in Studio and the code RoSignal inserts into an experience.

## Repository contents

### Studio plugin

- `plugin/RoSignalPlugin.server.lua` — the source used by the RoSignal Studio plugin. It handles pairing, installing/repairing scripts, and optional map export.

### Scripts inserted into your game

- `game/RoSignal.lua` — the generated runtime module placed in `ServerScriptService`.
- `game/RoSignalHandlers.server.lua` — the small developer-owned integration script placed in `ServerScriptService`.
- `game/RoSignalDemo.lua` — the optional starter UI inserted underneath `RoSignalHandlers` so the first live-setting and announcement tests are visible.
- `game/RoSignalSettings.lua` — the developer-owned map/event-position settings module placed in `ServerScriptService`.

That is the Roblox-side surface RoSignal installs. The hosted website/backend is not included in this repository.

## What the plugin does

The plugin:

1. connects to `https://rosignal.app`;
2. exchanges the one-time pairing code for a game-specific key and the latest script payload;
3. installs `RoSignal`, `RoSignalHandlers`, `RoSignalDemo`, and `RoSignalSettings`;
4. refreshes the generated `RoSignal` runtime during setup/repair while preserving developer-owned files;
5. stores the paired game key in Roblox Studio plugin settings for that place;
6. can export visible place geometry to RoSignal for the Analytics map.

## About `game/RoSignal.lua`

The live runtime contains a game-specific key, game id, and a few account-specific ingest values injected during pairing. Those private/generated values are intentionally not committed here.

The public copy uses obvious placeholders for the game key/id and shows the normal default ingest values. The runtime logic, API surface, endpoints, message handling, polling, aggregation, moderation handling, rollouts, traits, group-rank calls, and startup structure mirror the current RoSignal runtime.

Never publish a real `rsk_...` game key.

## Public API

The runtime's supported game-facing methods are grouped together in `installPublicApi()` so the API is easy to audit:

- `RoSignal.Get`
- `RoSignal.GetConfig` (legacy alias)
- `RoSignal.GetFor`
- `RoSignal.HasOverride`
- `RoSignal.InRollout`
- `RoSignal.SetTraits`
- `RoSignal.Bind`
- `RoSignal.OnKeyChange`
- `RoSignal.OnChange`
- `RoSignal.OnMessage`
- `RoSignal.OnAnnouncement`
- `RoSignal.Track`
- `RoSignal.SetRank`

Documentation: https://rosignal.app/docs

## What remains private

RoSignal's hosted service remains proprietary. That includes the dashboard, automation engine, database/server logic, billing, internal admin tooling, abuse prevention, and infrastructure.

Publishing this repository is for transparency and security review of the Roblox-side code, not for publishing the entire RoSignal service.

## Source status

This repository is intended to stay synchronized with the Roblox-side source used by the live RoSignal product. Behavior-affecting changes should be reflected here whenever the plugin/runtime changes.

## Security

If you find a security issue, do not post credentials, game keys, pairing codes, private user data, or sensitive exploit details in a public issue. See [SECURITY.md](SECURITY.md).

## License

No open-source license is currently granted. The source is published for transparency and security review. All rights are reserved unless stated otherwise in writing.
