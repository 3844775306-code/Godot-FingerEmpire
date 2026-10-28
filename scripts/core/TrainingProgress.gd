extends RefCounted

# 新兵训练营进度存档。
#
# 和战役进度分开保存，避免训练关污染闯关星级/体验期逻辑：
#   user://training_progress.json
#   {"version": 1, "levels": {"t01": {"stars": 2, "best_time": 180.0}}, "nations": [0, 2]}

const PATH := "user://training_progress.json"
const FORMAT_VERSION := 1
static var store_path: String = PATH

static func load_all() -> Dictionary:
	var data := {"version": FORMAT_VERSION, "levels": {}, "nations": []}
	if not FileAccess.file_exists(store_path):
		return data
	var f := FileAccess.open(store_path, FileAccess.READ)
	if f == null:
		return data
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return data
	var levels = parsed.get("levels", {})
	if typeof(levels) != TYPE_DICTIONARY:
		levels = {}
	var nations = parsed.get("nations", [])
	if typeof(nations) != TYPE_ARRAY:
		nations = []
	var normalized_nations: Array = []
	for n in nations:
		normalized_nations.append(int(n))
	data["levels"] = levels
	data["nations"] = normalized_nations
	return data

static func save_all(data: Dictionary) -> void:
	var out := {
		"version": FORMAT_VERSION,
		"levels": data.get("levels", {}),
		"nations": data.get("nations", []),
	}
	var tmp := store_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	if FileAccess.file_exists(store_path):
		DirAccess.remove_absolute(store_path)
	DirAccess.rename_absolute(tmp, store_path)

static func get_record(level_id: String) -> Dictionary:
	var all := load_all()
	var levels: Dictionary = all.get("levels", {})
	return levels.get(level_id, {}).duplicate()

static func best_stars(level_id: String) -> int:
	return int(get_record(level_id).get("stars", 0))

static func best_time(level_id: String) -> float:
	return float(get_record(level_id).get("best_time", 0.0))

static func is_cleared(level_id: String) -> bool:
	return best_stars(level_id) > 0

# 第一关永远开放；后续关卡要求上一关已通关。可选的高难关同样按顺序解锁。
static func is_unlocked(level_id: String) -> bool:
	var data := preload("res://scripts/data/TrainingData.gd")
	var order: int = int(data.level_order(level_id))
	if order <= 0:
		return true
	var prev: String = String(data.playable_levels()[order - 1].get("id", ""))
	return is_cleared(prev)

static func record_win(level_id: String, stars: int, elapsed: float) -> void:
	var all := load_all()
	var levels: Dictionary = all.get("levels", {})
	var rec: Dictionary = levels.get(level_id, {})
	var old_stars := int(rec.get("stars", 0))
	var old_time := float(rec.get("best_time", 0.0))
	rec["stars"] = maxi(old_stars, clampi(stars, 1, 3))
	if old_time <= 0.0 or elapsed < old_time:
		rec["best_time"] = elapsed
	levels[level_id] = rec
	all["levels"] = levels
	save_all(all)

static func mark_nation_seen(nation: int) -> void:
	var all := load_all()
	var nations: Array = all.get("nations", [])
	var n := int(nation)
	if not nations.has(n):
		nations.append(n)
	all["nations"] = nations
	save_all(all)

static func nation_seen(nation: int) -> bool:
	var all := load_all()
	for n in all.get("nations", []):
		if int(n) == int(nation):
			return true
	return false

static func nation_seen_count() -> int:
	var all := load_all()
	return all.get("nations", []).size()

# 已通关的主线关数（可选第 26 关单独计入高难，不占主线进度）
static func cleared_main_count() -> int:
	var data := preload("res://scripts/data/TrainingData.gd")
	var n := 0
	for lv in data.playable_levels():
		if String(lv.get("id", "")) == "t26":
			continue
		if is_cleared(String(lv.get("id", ""))):
			n += 1
	return n

static func cleared_optional_count() -> int:
	return 1 if is_cleared("t26") else 0

static func reset_all() -> void:
	if FileAccess.file_exists(store_path):
		DirAccess.remove_absolute(store_path)
