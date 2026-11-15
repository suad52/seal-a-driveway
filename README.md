# Seal A Driveway

A Roblox game about sealcoating driveways, with its source managed through [Rojo](https://rojo.space).

Play it on Roblox: https://www.roblox.com/games/120014184236770

## What's here

- `src/ServerScriptService` – server game logic and services
- `src/ReplicatedStorage` – shared modules, UI (`SealerUI`) and asset models
- `src/StarterPlayerScripts` – client scripts
- `src/StarterGui`, `src/ServerStorage`, `src/TestService`
- `default.project.json` – Rojo project file

Some asset folders are stored as `.rbxm` models because Rojo can't represent them as plain files (for example folders with duplicate-named children). The world map and terrain in Workspace are not included in this repo.

## Using it

```
rojo build -o SealADriveway.rbxlx
```

Or run `rojo serve` and connect from the Rojo plugin in Studio.
