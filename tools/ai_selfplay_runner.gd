extends Node

# AI 架构 v2 · P0 基线：AI 无头自对弈回归脚本
#
# 目的：给每次重构提供可自动对比的行为基线（同一 seed / 同一配置 / 同一指标口径）。
# 口径沿用 _diag_part.gd：交战中 / 推进中 / 完全待命 / 空走 / 其他，保证与历史实测可比。
#
# 用法（项目根目录，Godot 4.7）：
#   <Godot.exe> --headless --path . tools/ai_selfplay.tscn -- \
#       --seeds=24680,12345 --minutes=10 --sample=60 --mode=3v3 --diff=HELL \
#       --time-scale=8 --immortal=1 --prog=research
#
# 输出（自动打印绝对路径）：
#   user://ai_selfplay/<时间戳>/seed_<id>_samples.csv   全局帧耗时/实体数
#   user://ai_selfplay/<时间戳>/seed_<id>_peers.csv     每个 AI 的兵力/农民/防御/角色
#   user://ai_selfplay/<时间戳>/summary.json            各 seed 汇总 + 配置

const BATTLE_SCENE: String = "res://scenes/rts_battle.tscn"
const WALL_CAP_SEC: float = 420.0
const OUT_ROOT: String = "res://docs/ai-analysis/selfplay"

var _seeds: Array = [24680]
var _minutes: float = 10.0
var _sample_interval: float = 60.0
var _mode: String = "3v3"
var _diff: String = "HELL"
var _time_scale: float = 8.0
var _immortal: bool = true
var _progression: String = "research"
var _out_root: String = OUT_ROOT

var _battle: Node = null
var _frame_us: Array = []
var _last_usec: int = 0
var _t_start: int = 0
var _summaries: Array = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = 0
	_parse_args()
	_ensure_out_dir()
	_last_usec = Time.get_ticks_usec()
	print("[SELFPLAY] config seeds=%s minutes=%.0f mode=%s diff=%s scale=%.0f immortal=%s prog=%s" % [
		str(_seeds), _minutes, _mode, _diff, _time_scale, str(_immortal), _progression])
	print("[SELFPLAY] out=", ProjectSettings.globalize_path(_out_root))
	for s in _seeds:
		await _run_seed(int(s))
	_write_summary()
	print("[SELFPLAY] ALL DONE out=", ProjectSettings.globalize_path(_out_root))
	get_tree().quit()

func _process(_delta: float) -> void:
	var now: int = Time.get_ticks_usec()
	var dt: int = now - _last_usec
	_last_usec = now
	# 只记录正常帧间隔；切场景/等待的大跳变不计入耗时统计。
	if dt > 0 and dt < 2000000:
		_frame_us.append(dt)

# ───────────────────────── 参数与环境 ─────────────────────────

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			continue
		var kv: PackedStringArray = a.substr(2).split("=", true, 1)
		var k: String = kv[0]
		var v: String = kv[1] if kv.size() > 1 else "1"
		match k:
			"seeds":
				_seeds.clear()
				for part in v.split(",", false):
					if part.strip_edges() != "":
						_seeds.append(int(part))
			"minutes":
				_minutes = maxf(0.5, float(v))
			"sample":
				_sample_interval = maxf(5.0, float(v))
			"mode":
				_mode = v.to_lower()
			"diff":
				_diff = v.to_upper()
			"time-scale", "time_scale", "scale":
				_time_scale = clampf(float(v), 1.0, 16.0)
			"immortal":
				_immortal = v != "0" and v.to_lower() != "false"
			"prog":
				_progression = v.to_lower()
			"out":
				_out_root = v
	if _seeds.is_empty():
		_seeds = [24680]

func _ensure_out_dir() -> void:
	if not _out_root.begins_with("user://") and not _out_root.begins_with("res://"):
		# 允许传绝对路径
		DirAccess.make_dir_recursive_absolute(_out_root)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_root))

func _difficulty_value() -> int:
	match _diff:
		"EASY": return GameSettings.AIDifficulty.EASY
		"NORMAL": return GameSettings.AIDifficulty.NORMAL
		"HARD": return GameSettings.AIDifficulty.HARD
		_: return GameSettings.AIDifficulty.HELL

func _apply_settings(seed_id: int) -> void:
	# 固定随机：全局 RNG（旧代码仍用）+ 模拟随机种子，保证同一 seed 可复现。
	seed(seed_id)
	GameSettings.sim_seed = seed_id
	GameSettings.map_seed = seed_id
	GameSettings.map_id = "classic"
	GameSettings.ai_difficulty = _difficulty_value()
	GameSettings.blue_ai_difficulty = _difficulty_value()
	GameSettings.red_ai_difficulty = _difficulty_value()
	GameSettings.progression_mode = GameSettings.ProgressionMode.RESEARCH \
			if _progression.begins_with("research") else GameSettings.ProgressionMode.CLASSIC
	GameSettings.is_ffa = false
	match _mode:
		"1v1":
			GameSettings.ai_mode = 1
		"2v2":
			GameSettings.ai_mode = 2
		"ffa3", "ffa4", "ffa5":
			GameSettings.is_ffa = true
			GameSettings.ai_mode = 1
			GameSettings.ffa_nation_count = int(_mode.substr(3))
		_:
			GameSettings.ai_mode = 3

# ───────────────────────── 单局 ─────────────────────────

func _run_seed(seed_id: int) -> void:
	_apply_settings(seed_id)
	_frame_us.clear()
	_t_start = Time.get_ticks_msec()
	get_tree().change_scene_to_file(BATTLE_SCENE)
	while get_tree().current_scene == null or not get_tree().current_scene.has_method("simulation_checksum"):
		await get_tree().process_frame
	_battle = get_tree().current_scene
	await get_tree().create_timer(1.0).timeout
	if not is_instance_valid(_battle):
		print("[SELFPLAY] seed=%d scene lost" % seed_id)
		return
	var ais: Array = []
	for c in _battle.get_children():
		if c is AIController and is_instance_valid(c):
			ais.append(c)
	if _immortal:
		# 基线只关心 AI 行为指标，不希望 12 分钟后城堡被打掉中断采样。
		for b in _battle._buildings:
			if is_instance_valid(b) and int(b.entity_id) == 20:
				b.health = 99999999.0
	Engine.time_scale = _time_scale
	var next_t: float = _sample_interval
	var rows: Array = []
	var end_reason: String = "time"
	print("[SELFPLAY] seed=%d start ais=%d t_scale=%.0f" % [seed_id, ais.size(), _time_scale])
	while is_instance_valid(_battle) and get_tree().current_scene == _battle:
		await get_tree().process_frame
		if not is_instance_valid(_battle) or get_tree().current_scene != _battle:
			end_reason = "scene"
			break
		var gt: float = float(_battle.game_time)
		if gt >= next_t:
			next_t += _sample_interval
			rows.append(_sample(gt, ais))
			_frame_us.clear()
		if gt >= _minutes * 60.0:
			end_reason = "time"
			break
		if bool(_battle.get("game_over")):
			end_reason = "game_over"
			break
		if Time.get_ticks_msec() - _t_start > int(WALL_CAP_SEC * 1000.0):
			end_reason = "wall_cap"
			break
	Engine.time_scale = 1.0
	_write_seed_csv(seed_id, rows)
	var summary: Dictionary = _summarize(seed_id, rows, end_reason, ais.size())
	_summaries.append(summary)
	print("[SELFPLAY] seed=%d done reason=%s samples=%d wall=%.1fs" % [
		seed_id, end_reason, rows.size(), float(Time.get_ticks_msec() - _t_start) / 1000.0])

# ───────────────────────── 采样 ─────────────────────────

func _frame_pct(p: float) -> float:
	if _frame_us.is_empty():
		return 0.0
	var arr: Array = _frame_us.duplicate()
	arr.sort()
	var idx: int = clampi(int(float(arr.size() - 1) * p), 0, arr.size() - 1)
	return float(arr[idx]) / 1000.0

func _sample(gt: float, ais: Array) -> Dictionary:
	var cls: Dictionary = {"engage": 0, "push": 0, "idle": 0, "move": 0, "other": 0}
	var ai_peers: Dictionary = {}
	for a in ais:
		if is_instance_valid(a):
			ai_peers[int(a.my_peer_id)] = true
	for u in _battle._armies:
		if not is_instance_valid(u) or u.health <= 0:
			continue
		if int(u.entity_id) == 10 or int(u.attack) <= 0:
			continue
		var owner: int = int(u.owner_peer_id)
		if not ai_peers.has(owner):
			continue
		var order: String = str(u.current_order)
		var tgt = u.current_target
		if order == "attack" and tgt != null and is_instance_valid(tgt):
			cls["engage"] = int(cls["engage"]) + 1
		elif order == "attack_move":
			cls["push"] = int(cls["push"]) + 1
		elif order in ["", "idle"]:
			cls["idle"] = int(cls["idle"]) + 1
		elif order == "move":
			cls["move"] = int(cls["move"]) + 1
		else:
			cls["other"] = int(cls["other"]) + 1
	var peers: Array = []
	for a in ais:
		if not is_instance_valid(a):
			continue
		peers.append(_peer_row(a))
	var checksum: Dictionary = {}
	if _battle.has_method("simulation_checksum"):
		checksum = _battle.simulation_checksum()
	return {
		"t": gt,
		"entities": _battle._all_entities.size() if _battle.get("_all_entities") != null else 0,
		"armies": _battle._armies.size(),
		"p50": _frame_pct(0.50),
		"p95": _frame_pct(0.95),
		"class": cls,
		"peers": peers,
		"checksum": int(checksum.get("hash", 0)) if checksum is Dictionary else 0,
	}

func _peer_row(ai) -> Dictionary:
	var peer: int = int(ai.my_peer_id)
	var key: int = peer if peer != -1 else int(ai.my_team)
	var row: Dictionary = {"peer": peer, "team": int(ai.my_team), "phase": int(ai.phase)}
	row["land"] = int(ai.count_land_army()) if ai.has_method("count_land_army") else -1
	row["field"] = int(ai.count_field_military(key)) if ai.has_method("count_field_military") else -1
	row["workers"] = -1
	row["queued_workers"] = -1
	row["builders"] = -1
	row["train_block"] = ""
	var wd = ai.get("_worker_director")
	if wd != null and wd.has_method("debug_snapshot"):
		var snap: Dictionary = wd.debug_snapshot()
		row["workers"] = int(snap.get("live", -1))
		row["queued_workers"] = int(snap.get("queued", -1))
		row["builders"] = int(snap.get("builders", -1))
		row["train_block"] = String(snap.get("train_block", ""))
	row["threat"] = -1
	row["posture"] = -1
	row["ring"] = -1
	var d = ai.get("_defense")
	if d != null:
		row["threat"] = int(d.threat_level)
		if d.has_method("get_defense_posture"):
			row["posture"] = int(d.get_defense_posture())
		if d.has_method("get_defense_plan"):
			var plan: Dictionary = d.get_defense_plan()
			row["ring"] = (plan.get("rings", []) as Array).size()
	return row

# ───────────────────────── 输出 ─────────────────────────

func _write_seed_csv(seed_id: int, rows: Array) -> String:
	var samples_path: String = "%s/seed_%d_samples.csv" % [_out_root, seed_id]
	var peers_path: String = "%s/seed_%d_peers.csv" % [_out_root, seed_id]
	var f: FileAccess = FileAccess.open(samples_path, FileAccess.WRITE)
	if f != null:
		f.store_line("seed,t,entities,armies,frame_p50_ms,frame_p95_ms,engage,push,idle,move,other,checksum")
		for r in rows:
			var c: Dictionary = r["class"]
			f.store_line("%d,%.0f,%d,%d,%.2f,%.2f,%d,%d,%d,%d,%d,%d" % [
				seed_id, float(r["t"]), int(r["entities"]), int(r["armies"]),
				float(r["p50"]), float(r["p95"]),
				int(c["engage"]), int(c["push"]), int(c["idle"]), int(c["move"]), int(c["other"]),
				int(r["checksum"])])
		f.close()
	var p: FileAccess = FileAccess.open(peers_path, FileAccess.WRITE)
	if p != null:
		p.store_line("seed,t,peer,team,phase,land,field,workers,queued_workers,builders,train_block,threat,posture,rings")
		for r in rows:
			for pr in r["peers"]:
				p.store_line("%d,%.0f,%d,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d" % [
					seed_id, float(r["t"]), int(pr["peer"]), int(pr["team"]), int(pr["phase"]),
					int(pr["land"]), int(pr["field"]), int(pr["workers"]), int(pr["queued_workers"]),
					int(pr["builders"]), String(pr["train_block"]),
					int(pr["threat"]), int(pr["posture"]), int(pr["ring"])])
		p.close()
	return samples_path

func _summarize(seed_id: int, rows: Array, end_reason: String, ai_count: int) -> Dictionary:
	var tot: Dictionary = {"engage": 0, "push": 0, "idle": 0, "move": 0, "other": 0}
	var p95: float = 0.0
	var workers: float = 0.0
	var land: float = 0.0
	var n: int = 0
	for r in rows:
		var c: Dictionary = r["class"]
		for k in tot:
			tot[k] = int(tot[k]) + int(c[k])
		p95 = maxf(p95, float(r["p95"]))
		for pr in r["peers"]:
			workers += float(pr["workers"])
			land += float(pr["land"])
			n += 1
	var sum_units: float = maxf(1.0, float(tot["engage"] + tot["push"] + tot["idle"] + tot["move"] + tot["other"]))
	var out: Dictionary = {
		"seed": seed_id,
		"end_reason": end_reason,
		"samples": rows.size(),
		"ai_count": ai_count,
		"last_t": float(rows[-1]["t"]) if not rows.is_empty() else 0.0,
		"engage_pct": float(tot["engage"]) / sum_units * 100.0,
		"push_pct": float(tot["push"]) / sum_units * 100.0,
		"idle_pct": float(tot["idle"]) / sum_units * 100.0,
		"front_pct": float(tot["engage"] + tot["push"]) / sum_units * 100.0,
		"frame_p95_ms_max": p95,
		"workers_avg": workers / maxf(1.0, float(n)),
		"land_avg": land / maxf(1.0, float(n)),
	}
	print("[SELFPLAY] seed=%d engage=%.1f%% push=%.1f%% idle=%.1f%% front=%.1f%% p95max=%.1fms workers=%.1f land=%.1f" % [
		seed_id, float(out["engage_pct"]), float(out["push_pct"]), float(out["idle_pct"]),
		float(out["front_pct"]), p95, float(out["workers_avg"]), float(out["land_avg"])])
	return out

func _write_summary() -> void:
	var path: String = "%s/summary.json" % _out_root
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var data: Dictionary = {
		"generated_at": Time.get_datetime_string_from_system(),
		"config": {
			"seeds": _seeds, "minutes": _minutes, "sample": _sample_interval,
			"mode": _mode, "difficulty": _diff, "time_scale": _time_scale,
			"immortal": _immortal, "progression": _progression,
		},
		"seeds": _summaries,
	}
	f.store_string(JSON.stringify(data, "  "))
	f.close()
