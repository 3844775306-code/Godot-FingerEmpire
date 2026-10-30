# AI 无头自对弈基线（P0）

> 目的：给 AI 重构提供**可自动对比的行为基线**。同一 seed + 同一配置 + 同一指标口径，
> 每次改动后跑一遍，对比 `summary.json` 就能判断有没有回归。
> 设计背景见 [AI_ARCHITECTURE_V2.md](../AI_ARCHITECTURE_V2.md) 第 6 节 P0。

## 运行方式

```powershell
# 项目根目录。用 console 版 Godot 才能拿到 stdout。
$Godot = "<Godot 4.7 可执行文件>"
& $Godot --headless --path . res://tools/ai_selfplay.tscn -- `
    --seeds=24680 --minutes=8 --sample=60 --mode=3v3 --diff=HELL `
    --time-scale=8 --immortal=1 --prog=research
```

| 参数 | 默认 | 说明 |
|------|------|------|
| `--seeds=` | `24680` | 逗号分隔，可多局串行 |
| `--minutes=` | `10` | 每局采样到的游戏时长（分钟，游戏内时间） |
| `--sample=` | `60` | 采样间隔（游戏内秒） |
| `--mode=` | `3v3` | `1v1` / `2v2` / `3v3` / `ffa3` / `ffa4` / `ffa5` |
| `--diff=` | `HELL` | `EASY` / `NORMAL` / `HARD` / `HELL`（红蓝同档） |
| `--time-scale=` | `8` | 加速倍率 1~16；**改动前后必须一致**，否则帧耗时不可比 |
| `--immortal=` | `1` | 城堡血量锁死，避免中途结束导致样本变短 |
| `--prog=` | `research` | `research` / `classic` |
| `--out=` | `res://docs/ai-analysis/selfplay` | 输出目录（可传绝对路径） |

运行时长参考：8 游戏分钟 @ 8x ≈ **73 秒**墙钟（3v3、5 AI、500 实体）。

## 输出

```
docs/ai-analysis/selfplay/
  seed_<id>_samples.csv   # 每次采样一行：全局
  seed_<id>_peers.csv     # 每次采样 × 每个 AI 一行
  summary.json            # 配置 + 每 seed 汇总（回归只看这个）
```

`samples.csv` 列：`t, entities, armies, frame_p50_ms, frame_p95_ms, engage, push, idle, move, other, checksum`
`peers.csv` 列：`peer, team, phase, land, field, workers, queued_workers, builders, train_block, threat, posture, rings`
`checksum`：`battle.simulation_checksum()`，可用于确定性对比（同 seed 同指令应一致）。

## 指标口径（沿用 `_diag_part.gd`，保证与历史实测可比）

统计对象：**AI 拥有的陆军战斗单位**（`entity_id != 10`、`attack > 0`、`owner_peer_id ∈ AI 列表`）。

| 分类 | 条件 |
|------|------|
| 交战中 `engage` | `current_order == "attack"` 且 `current_target` 有效 |
| 推进中 `push` | `current_order == "attack_move"` |
| 完全待命 `idle` | `current_order ∈ ["", "idle"]` |
| 空走 `move` | `current_order == "move"`（有移动无目标） |
| 其他 `other` | 其余（如 `build`、`gather`） |

`summary.json` 中 `front_pct = engage% + push%`（作者提交信息里的"前线参与"口径）。

## 已知口径差异 / 注意事项

1. **与作者提交里的历史数字不完全同源**：作者实测未固定 `progression_mode`（默认 CLASSIC），本脚本默认 `research`；且作者可能排除了驻军/船上单位。对比时先固定 `--prog` 与统计口径。
2. **待命率偏高（首轮 23%）**：`idle` 目前包含"在城堡/建筑内驻军（order 为空）"的单位，后续建议在指标里增加 `garrisoned` 拆分（不改主口径，另加列）。
3. **阶段指标（已修）**：首轮基线发现所有 AI 的 `phase` 始终为 1（DEVELOPMENT）——`AI.gd` step 11 用 `count_field_military() >= 30`，而军队账本接管后 field 被扣到个位数，ASSAULT 永远不触发。已改为 `count_land_army() >= ASSAULT_LAND_ARMY_THRESHOLD`（14），对照数据在 `docs/ai-analysis/selfplay/after_phase_fix/`：ASSAULT 于 t=420/540/600 触发。
4. **headless 噪声**：启动时的 `SteamMultiplayerPeer` 注册错误、`user://logs` 写失败都不影响运行（项目无 Steam 环境）。
5. **不要在编辑器打开同一项目时跑**：两实例会争 `.godot` 导入缓存，可能卡住；先关编辑器再跑。
6. 脚本结构：`tools/ai_selfplay.tscn` → `tools/ai_selfplay.gd`（启动器，把 runner 挂到 SceneTree root）→ `tools/ai_selfplay_runner.gd`（真正逻辑）。**runner 不能是场景根节点**，否则 `change_scene_to_file` 会把它释放。
