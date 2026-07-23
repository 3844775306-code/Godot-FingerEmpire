# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FingerEmpire** — a server-authoritative medieval RTS built in Godot 4.5 (Forward Plus). Features 5 nations (Viking, England, France, China, Hungary), resource economy, fog of war, A* pathfinding, and online multiplayer via ENet. Supports 1v1 and 2v2 modes with AI bots, plus a local singleplayer mode.

## Opening the project

Open `project.godot` in the Godot 4.5 editor. The main scene is configured there. There are no command-line build/test steps — everything runs through the Godot editor.

## Architecture

### Autoloaded Singletons (defined in `project.godot` `[autoload]`)
These are globally accessible nodes loaded before any scene:

| Singleton | Script | Purpose |
|-----------|--------|---------|
| `RTSConfig` | `scripts/core/RTSConfig.gd` | Global constants (MAP_SIZE, Team enum, Nation enum, COLOR_POOL, ENTITY_MODELS map) |
| `GameManager` | `scripts/core/GameManager.gd` | Scene-level state machine (MENU → PLAYING → GAME_OVER); switches between `main_menu.tscn` and `rts_battle.tscn` |
| `EntityDatabase` | `scripts/core/EntityDatabase.gd` | Central registry of all entity configs (IDs 0–63: resources, buildings, armies, animals). `get_config(id)` returns a duplicated Dictionary. |
| `NetworkManager` | `scripts/core/NetworkManager.gd` | ENet multiplayer peer management. Modes: NONE/SERVER/CLIENT. RPCs for commands, snapshots, map data, nation selection. Port 9000. |
| `ThemeHelper` | `scripts/ui/ThemeHelper.gd` | UI theming utility |
| `GameSettings` | `scripts/core/GameSettings.gd` | Player settings (nation choice, AI difficulty, post-game data) |
| `AudioManager` | `scripts/core/AudioManager.gd` | Music and SFX playback (play_music, play_sfx, play_sfx_3d) |
| `Profiler` | `scripts/core/Profiler.gd` | Performance profiling |

### Entity System (`scripts/entities/`)

Three entity types, all extending `GameEntity` (CharacterBody3D):

- **Army** (`Army.gd`) — mobile units (peasants, soldiers, ships, merchants, officials, animals). Has MovementController, combat AI, gathering, waypoints, garrison points.
- **Building** (`Building.gd`) — structures with production queues, upgrade system (5 levels), construction timers. Key IDs: 20=Castle (game-over on death), 21=Barracks, 25/26=Towers, 27=Walls, 28=Houses.
- **WorldResource** (`WorldResource.gd`) — gatherable resource nodes (gold, wood, stone, food, oil fields)

Entities are spawned via `RTSBattleManager.spawn_entity(config, team, pos, level)`, which loads 3D models (GLB), applies team tint, registers to the entity cache, and adjusts ground height.

### Server-Side Battle Managers

**`RTSBattleManager`** (`scripts/scenes/RTSBattleManager.gd`) — base class for both singleplayer and multiplayer. Owns:
- Entity cache system (`_entities_by_team`, `_armies`, `_buildings`, `_resources`, `_towers`) with dirty-flag pattern for O(1) lookups
- Fog of war (explored_grid/visible_grid, vision-based)
- Resource economy (player/enemy resources, limits, population)
- Building placement & validation
- Game-over detection (castle death)
- Power-history chart at end of match

**`OnlineBattleManager`** (`scripts/scenes/OnlineBattleManager.gd`) — extends RTSBattleManager for multiplayer. Adds:
- Delta-compressed incremental snapshots (every 100ms, full snapshot every ~3s)
- Compact array-based entity serialization (enum indices for wire format)
- Per-player visibility grids for snapshot culling
- Command processing (1v1 and 2v2 variants)
- AI player creation and management
- Resource limits and population per peer_id

### Client-Side (`scripts/client/`)

**`ClientRenderer`** (`scripts/client/ClientRenderer.gd`) — receives snapshots, creates/maintains entity nodes, handles:
- Snapshot delta application (compact array → Dictionary conversion)
- Entity node pooling (create on first sight, update positions via lerp interpolation)
- Client-side fog of war (incremental batch processing)
- Health bars, production bars, upgrade bars
- 3D model loading with team tint, weapons, mounts
- Waypoint/A* path visualization
- Sound effect dispatch based on state transitions and visibility

**`ClientInput`** (`scripts/client/ClientInput.gd`) — mouse/touch input, selection, right-click commands; sends actions to server via `NetworkManager.send_command`.

**`ClientHUD`** (`scripts/client/ClientHUD.gd`) — resource display, minimap, alerts, control groups.

### AI (`scripts/ai/AI.gd`)

`AIController` — attached per AI player (peer_id). Handles autonomous economy, unit training, scouting, and combat.

### Map (`scripts/map/`)

- `Ground.gd` — procedural terrain generation (perlin-based), terrain grid (plains/water/mountains), height grid, resource distribution, castle placement. Exposes `get_terrain()`, `get_height_at()`, `apply_fog()`.
- `Map.gd` — legacy map node
- `CameraController.gd` — RTS-style camera (pan, zoom, edge scrolling)
- `Minimap.gd` — minimap rendering with entity dots and alert flashes

### Data (`scripts/data/`)

- `NationData.gd` — nation-specific unit unlocks and tech trees
- `NationBonuses.gd` — static nation bonus values (population, starting castle level)

## Network Protocol

Commands sent client→server via `NetworkManager.send_command(data)` RPC. The `data` dictionary always has an `"action"` key:
- `right_click`, `build`, `upgrade`, `produce`, `global_attack`, `global_retreat`, `stop_gather`, `toggle_hold_position`, `rally`, `set_group`, `recall_group`, `demolish`, `set_garrison`, `clear_garrison`

Server→client snapshots are delta-compressed arrays sent at ~10Hz. Compact format uses enum indices (`E.ID=0`, `E.EID=1`, etc.) rather than string keys.

## Key Design Patterns

- **Entity cache with dirty flag**: `RTSBattleManager._ensure_cache_fresh()` — called before any query that needs entity lists. Rebuilds `_all_entities`, `_armies`, `_buildings`, `_resources`, `_towers`, `_entities_by_team`, `_entity_lookup` from the `$Entities` child list.
- **Config duplication**: `EntityDatabase.get_config()` always returns a `.duplicate()` — never modify the original.
- **Networked state ownership**: 1v1 uses team-based ownership; 2v2 uses `owner_peer_id` for per-player isolation.
- **Client model mirroring**: ClientRenderer replicates server entity state from snapshots, including 3D models, animations, and team tinting — it does NOT run game logic.

## Addons (in `addons/`)

- **godotsteam** — Steamworks SDK integration (not initialized on startup per project config)
- **script-ide** — enhanced script editor with outline, quick-open, split editing
- **github_copilot** — in-editor GitHub Copilot AI assistance
- **git_describe** — git describe info in editor title bar
- **godot-git-plugin** — version control integration (enabled in project settings)
