extends Node

# 地图生成探针：无头运行，输出各预设在不同种子下的网格/城堡/资源指纹与地形不变式。
# 运行：godot --headless --path . res://_probe_maps.tscn -- --map=ridge
# 用途：1) 重构前后比对经典图是否逐字节一致 2) 特殊地图连通性/基地条件检查

const SEEDS := [1, 2, 3]
const DEFAULT_MAP := "classic"
const GroundScript = preload("res://scripts/map/Ground.gd")

func _ready() -> void:
	GameSettings.ai_mode = 1
	GameSettings.is_ffa = false
	GameSettings.ffa_nation_count = 3
	GameSettings.ai_difficulty = 0
	NetworkManager.mode = NetworkManager.Mode.NONE

	var map_id := _read_map_arg()
	GameSettings.map_id = map_id
	print("PROBE map_id=%s map_size=%d" % [map_id, RTSConfig.MAP_SIZE])

	for s in SEEDS:
		var g = GroundScript.new()
		g.custom_seed = s
		seed(777)
		g._resolve_preset()
		g._generate_terrain()
		g._place_castles()
		g._place_resources()
		print("SEED %d TERRAIN %s HEIGHT %s CASTLE %s RES %s" % [
			s,
			_md5(g.terrain_grid),
			_md5(g.height_grid),
			_md5([g.player_castle_pos, g.enemy_castle_pos]),
			_md5(g.resource_positions),
		])
		_report(g, s)
		if s == SEEDS[0] and map_id != "classic":
			_ascii(g, RTSConfig.MAP_SIZE)
		g.free()

	get_tree().quit()

func _read_map_arg() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--map="):
			return a.substr(6)
	return DEFAULT_MAP

func _report(g, s: int) -> void:
	var size: int = RTSConfig.MAP_SIZE
	var counts := {0: 0, 1: 0, 2: 0}
	for x in range(size):
		for y in range(size):
			counts[int(g.terrain_grid[x][y])] += 1
	var total := float(size * size)
	var overlay_stats := {1: 0, 3: 0}
	if not g.overlay_grid.is_empty():
		for x in range(size):
			for y in range(size):
				var ov: int = int(g.overlay_grid[x][y])
				if overlay_stats.has(ov):
					overlay_stats[ov] += 1
	print("  STATS plain=%.1f%% mountain=%.1f%% water=%.1f%% passes=%d forest=%.1f%% ford=%.1f%%" % [
		counts[0] / total * 100.0, counts[1] / total * 100.0, counts[2] / total * 100.0,
		g._pass_centers.size(), overlay_stats[1] / total * 100.0, overlay_stats[3] / total * 100.0])

	for label in ["PLAYER", "ENEMY"]:
		var p: Vector3 = g.player_castle_pos if label == "PLAYER" else g.enemy_castle_pos
		var gx := int(p.x + size / 2.0)
		var gz := int(p.z + size / 2.0)
		var flat := true
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				if g.terrain_grid[gx + dx][gz + dy] != 0:
					flat = false
		var res := {}
		for r in g.resource_positions:
			if Vector2(r["pos"].x - p.x, r["pos"].z - p.z).length() <= 20.0:
				var t: int = int(r["type"])
				if t > 4:
					continue
				res[t] = int(res.get(t, 0)) + 1
		print("  %s grid=%d,%d terrain=%d h=%.2f flat5=%s res20=%s" % [
			label, gx, gz, g.terrain_grid[gx][gz], g.height_grid[gx][gz], str(flat), str(res)])

	print("  CROSS ford=%s noford=%s" % [
		str(_cross_connected(g, size, g.player_castle_pos, g.enemy_castle_pos, true)),
		str(_cross_connected(g, size, g.player_castle_pos, g.enemy_castle_pos, false))])

# 2 倍降采样的字符画：. 平原  ^ 山地  ~ 水域  P/E 城堡  | 隘口
func _ascii(g, size: int) -> void:
	var step := 2
	var rows: Array = []
	for y in range(0, size, step):
		var line := ""
		for x in range(0, size, step):
			var t: int = g.terrain_grid[x][y]
			var ov: int = 0
			if not g.overlay_grid.is_empty():
				ov = int(g.overlay_grid[x][y])
			if ov == 3:
				line += "="
			elif ov == 1:
				line += "f"
			else:
				line += "." if t == 0 else ("^" if t == 1 else "~")
		rows.append(line)
	for pc in g._pass_centers:
		_set_char(rows, int(pc.x / step), int(pc.y / step), "|")
	_set_char(rows, int((g.player_castle_pos.x + size / 2.0) / step), int((g.player_castle_pos.z + size / 2.0) / step), "P")
	_set_char(rows, int((g.enemy_castle_pos.x + size / 2.0) / step), int((g.enemy_castle_pos.z + size / 2.0) / step), "E")
	print("ASCII 2x:")
	for line in rows:
		print(line)

func _set_char(rows: Array, x: int, y: int, ch: String) -> void:
	if y < 0 or y >= rows.size():
		return
	var line: String = rows[y]
	if x < 0 or x >= line.length():
		return
	rows[y] = line.substr(0, x) + ch + line.substr(x + 1)

# 陆地连通性：allow_ford 时浅滩算可通行（仍挡山地/深水）
func _cross_connected(g, size: int, a: Vector3, b: Vector3, allow_ford: bool) -> bool:
	var start := Vector2i(int(a.x + size / 2.0), int(a.z + size / 2.0))
	var goal := Vector2i(int(b.x + size / 2.0), int(b.z + size / 2.0))
	var seen := {start: true}
	var q: Array = [start]
	while not q.is_empty():
		var cur: Vector2i = q.pop_front()
		if cur == goal:
			return true
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
				continue
			if seen.has(n):
				continue
			var t: int = g.terrain_grid[n.x][n.y]
			var ov: int = 0
			if not g.overlay_grid.is_empty():
				ov = int(g.overlay_grid[n.x][n.y])
			if t != 0 and not (allow_ford and ov == 3):
				continue
			seen[n] = true
			q.append(n)
	return false

func _md5(v) -> String:
	return var_to_bytes(v).hex_encode().md5_text()
