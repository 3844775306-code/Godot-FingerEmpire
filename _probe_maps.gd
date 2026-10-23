extends Node

# 地图生成探针：无头运行，输出各预设在不同种子下的网格/城堡/资源指纹与地形不变式。
# 运行：godot --headless --path . res://_probe_maps.tscn -- --map=ridge
# 用途：1) 重构前后比对经典图是否逐字节一致 2) 特殊地图连通性/基地条件检查

const SEEDS := [1, 2, 3]
const DEFAULT_MAP := "classic"
const GroundScript = preload("res://scripts/map/Ground.gd")
const MapPreview = preload("res://scripts/map/MapPreview.gd")
const MapPresets = preload("res://scripts/map/MapPresets.gd")

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

	_preview_selfcheck()
	_sync_selfcheck()
	# 多人布局自检会改 NetworkManager 模式，放最后
	for id in ["ridge", "ford", "forest", "marsh", "strait", "desert"]:
		for k in [2, 3]:
			_team_probe(id, k)
	get_tree().quit()

# 多人布局自检：2V2/3V3（150 格）每方 2/3 个基地，沿镜像轴对称、脚下必为平原
func _team_probe(map_id: String, team_size: int) -> void:
	NetworkManager.mode = NetworkManager.Mode.SERVER
	NetworkManager.selected_mode = NetworkManager.GameMode.TWOVTWO if team_size == 2 else NetworkManager.GameMode.THREEvTHREE
	GameSettings.is_ffa = false
	NetworkManager._apply_map_size_for_mode()
	print("MAPSIZE %s %dv%d -> %d" % [map_id, team_size, team_size, RTSConfig.MAP_SIZE])
	var size := 150
	var g = GroundScript.new()
	g.map_size_override = size
	g.map_preset = MapPresets.get_preset(map_id)
	g.custom_seed = 4242
	g._generate_with_stages(size, g.map_preset["stages"])
	g._place_castles()
	g._place_resources()
	var pts: Array = g.multi_castle_positions
	var mid := size / 2.0
	var mirror_ok := true
	for i in range(team_size):
		var b = pts[i]
		var r = pts[team_size + i]
		var bx := int(b.x + mid)
		var bz := int(b.z + mid)
		var rx := int(r.x + mid)
		var rz := int(r.z + mid)
		if map_id == "ridge":
			# 山脊东西走向 → 南北镜像（z 互补，x 相同）
			if absi(bx - rx) > 2 or absi((bz + rz) - size) > 3:
				mirror_ok = false
		else:
			# 渡口/黑森林河流南北走向 → 东西镜像（x 互补，z 相同）
			if absi(bz - rz) > 2 or absi((bx + rx) - size) > 3:
				mirror_ok = false
	var flat_ok := true
	for p in pts:
		var gx := int(p.x + mid)
		var gy := int(p.z + mid)
		for dx in range(-2, 3):
			for dy in range(-2, 3):
				if g.terrain_grid[gx + dx][gy + dy] != 0:
					flat_ok = false
	var gold := 0
	var wood := 0
	for r in g.resource_positions:
		var t: int = int(r["type"])
		if t == 0:
			gold += 1
		elif t == 1:
			wood += 1
	var water := 0
	for x in range(size):
		for y in range(size):
			if int(g.terrain_grid[x][y]) == 2:
				water += 1
	print("TEAM %s %dv%d bases=%d mirror=%s flat=%s gold=%d wood=%d water=%.1f%%" % [
		map_id, team_size, team_size, pts.size(), str(mirror_ok), str(flat_ok),
		gold, wood, float(water) / float(size * size) * 100.0])
	g.free()

# 模拟联机下发：主机打包覆盖层 → 客户端解压并还原，地形/覆盖层/配色必须一致
func _sync_selfcheck() -> void:
	var size := 100
	for pid in ["marsh", "desert", "strait"]:
		var src = GroundScript.new()
		src.map_size_override = size
		src.map_preset = MapPresets.get_preset(pid)
		src.custom_seed = 12345
		src._generate_with_stages(size, src.map_preset["stages"])
		var overlay := PackedByteArray()
		overlay.resize(size * size)
		var oi := 0
		for x in range(size):
			for y in range(size):
				overlay[oi] = src.get_overlay(x, y)
				oi += 1
		var zip := overlay.compress(FileAccess.COMPRESSION_ZSTD)
		var unzip := zip.decompress(size * size, FileAccess.COMPRESSION_ZSTD)
		var dst = GroundScript.new()
		dst.map_size_override = size
		dst.apply_received_map(src.terrain_grid, src.height_grid, [], unzip, pid)
		var same := var_to_bytes([src.terrain_grid, src.overlay_grid]) == var_to_bytes([dst.terrain_grid, dst.overlay_grid])
		var same_colors := var_to_bytes(src.base_colors) == var_to_bytes(dst.base_colors)
		print("SYNC %s match=%s colors=%s zip=%d raw=%d mods=%s" % [
			pid, str(same), str(same_colors), zip.size(), overlay.size(),
			str(dst.map_preset.get("modifiers", {}))])
		src.free()
		dst.free()

func _preview_selfcheck() -> void:
	for id in MapPresets.all_ids():
		var tex = MapPreview.get_texture(id, 64)
		print("PREVIEW %s %s" % [id, str(tex.get_size()) if tex else "null"])

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
	var overlay_stats := {1: 0, 2: 0, 3: 0}
	if not g.overlay_grid.is_empty():
		for x in range(size):
			for y in range(size):
				var ov: int = int(g.overlay_grid[x][y])
				if overlay_stats.has(ov):
					overlay_stats[ov] += 1
	print("  STATS plain=%.1f%% mountain=%.1f%% water=%.1f%% passes=%d forest=%.1f%% marsh=%.1f%% ford=%.1f%%" % [
		counts[0] / total * 100.0, counts[1] / total * 100.0, counts[2] / total * 100.0,
		g._pass_centers.size(), overlay_stats[1] / total * 100.0, overlay_stats[2] / total * 100.0, overlay_stats[3] / total * 100.0])

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

	# 资源统计 + 地形一致性（木材是否落在森林、金矿是否都在隘口）
	var type_counts := {}
	var wood_total := 0
	var wood_in_forest := 0
	var wood_edge := 0
	var gold_total := 0
	var gold_at_passes := 0
	for r in g.resource_positions:
		var t: int = int(r["type"])
		if t > 4:
			continue
		type_counts[t] = int(type_counts.get(t, 0)) + 1
		var wx := int(r["pos"].x + size / 2.0)
		var wy := int(r["pos"].z + size / 2.0)
		if t == 1:
			wood_total += 1
			if g.get_overlay(wx, wy) == 1:
				wood_in_forest += 1
			elif g._forest_edge(wx, wy, size):
				wood_edge += 1
		elif t == 0:
			gold_total += 1
			for pc in g._pass_centers:
				# 组心落在隘口 6 格内，成员±4 散开，用 14 判定整组都在隘口
				if Vector2(wx - pc.x, wy - pc.y).length() <= 14.0:
					gold_at_passes += 1
					break
	print("  RES %s" % str(type_counts))
	print("  WOOD total=%d in_forest=%d edge=%d" % [wood_total, wood_in_forest, wood_edge])
	# 动物（兽群）数量与孤岛统计：海峡图应有一批与两岸不连通的隔离岛，且资源全部可达
	var animals := 0
	for r in g.resource_positions:
		if int(r["type"]) >= 60:
			animals += 1
	print("  ANIMALS %d" % animals)
	_report_islands(g, size)
	# 单株分布检查（黑森林）：木材贴林线排列，允许相邻紧贴，但不应成簇（同格重叠）
	if GameSettings.map_id == "forest":
		var wpos: Array = []
		for r in g.resource_positions:
			if int(r["type"]) == 1:
				wpos.append(Vector2(r["pos"].x + size / 2.0, r["pos"].z + size / 2.0))
		var min_gap := 999.0
		for i in range(wpos.size()):
			for j in range(i + 1, wpos.size()):
				min_gap = minf(min_gap, wpos[i].distance_to(wpos[j]))
		var edge_total := 0
		for x in range(3, size - 4):
			for y in range(3, size - 4):
				if g.terrain_grid[x][y] == 0 and g.get_overlay(x, y) == 0 and g._forest_edge(x, y, size):
					edge_total += 1
		print("  WOOD_GAP min=%.1f n=%d EDGE tiles=%d cover=%.0f%%" % [
			min_gap, wpos.size(), edge_total,
			float(wpos.size()) / maxf(1.0, float(edge_total)) * 100.0])
		# 候选池规模（与放置器同口径：成片森林边界）
		var cand_total := 0
		for x in range(3, size - 4):
			for y in range(3, size - 4):
				if g.terrain_grid[x][y] != 0 or g.get_overlay(x, y) != 0:
					continue
				if not g._forest_edge(x, y, size):
					continue
				if g._forest_count_near(x, y, 3) < 8:
					continue
				cand_total += 1
		print("  WOOD_CAND pool=%d" % cand_total)
	if not g._pass_centers.is_empty():
		print("  GOLD total=%d at_passes=%d" % [gold_total, gold_at_passes])
	# 浅滩沙色抽样：应当是多种深浅不同的沙色，而不是单一纯色
	var ford_cols := {}
	for x in range(size):
		for y in range(size):
			if g.get_overlay(x, y) == 3:
				ford_cols[g.base_colors[x][y].to_html(false)] = true
	if not ford_cols.is_empty():
		var keys := ford_cols.keys()
		var sample := []
		for i in range(mini(4, keys.size())):
			sample.append(keys[i])
		print("  FORD_COLORS distinct=%d sample=%s" % [keys.size(), str(sample)])

# 孤岛统计：从两座城堡洪水填充，统计与两岸不连通的陆地格与连通块数；
# 同时确认没有落在孤岛上的资源（海峡图 reachable_only 会剔除）
func _report_islands(g, size: int) -> void:
	var reach := {}
	var q: Array = []
	for p in [g.player_castle_pos, g.enemy_castle_pos]:
		var c := Vector2i(int(p.x + size / 2.0), int(p.z + size / 2.0))
		if not reach.has(c):
			reach[c] = true
			q.append(c)
	while not q.is_empty():
		var cur: Vector2i = q.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cur + d
			if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
				continue
			if reach.has(n):
				continue
			if int(g.terrain_grid[n.x][n.y]) == 2 and g.get_overlay(n.x, n.y) != 3:
				continue
			reach[n] = true
			q.append(n)
	var island_tiles := 0
	var islands := 0
	var seen := {}
	for x in range(size):
		for y in range(size):
			if int(g.terrain_grid[x][y]) == 2 or reach.has(Vector2i(x, y)):
				continue
			if seen.has(Vector2i(x, y)):
				continue
			islands += 1
			var bq: Array = [Vector2i(x, y)]
			seen[Vector2i(x, y)] = true
			while not bq.is_empty():
				var cur: Vector2i = bq.pop_back()
				island_tiles += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = cur + d
					if n.x < 0 or n.y < 0 or n.x >= size or n.y >= size:
						continue
					if seen.has(n) or reach.has(n):
						continue
					if int(g.terrain_grid[n.x][n.y]) == 2:
						continue
					seen[n] = true
					bq.append(n)
	var unreachable_res := 0
	for r in g.resource_positions:
		var gx := int(r["pos"].x + size / 2.0)
		var gy := int(r["pos"].z + size / 2.0)
		var ok: bool = reach.has(Vector2i(gx, gy))
		# 水面资源站在岸边就能采，相邻陆地可达即算可达
		if not ok and int(g.terrain_grid[gx][gy]) == 2:
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if reach.has(Vector2i(gx, gy) + d):
					ok = true
					break
		if not ok:
			unreachable_res += 1
	print("  ISLANDS n=%d tiles=%d unreachable_res=%d" % [islands, island_tiles, unreachable_res])

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
			elif ov == 2:
				line += "m"
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
