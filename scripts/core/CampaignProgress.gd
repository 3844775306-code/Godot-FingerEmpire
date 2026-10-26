extends RefCounted

# 闯关模式进度存档。
#
# 存在 user://campaign_progress.json，结构：
#   {"version": 1, "levels": {"c1_1": {"stars": 3, "best_time": 412.5}}}
# 只记录通关过哪些关、每关最高星级和最好用时；关卡内容本身在 CampaignData.gd。

const PATH := "user://campaign_progress.json"
const FORMAT_VERSION := 1
# 实际读写路径；正常运行时等于 PATH，自动化测试可以临时指向别的文件
static var store_path: String = PATH

# 读取全部进度；文件不存在/损坏时返回空结构（不报错，避免坏档卡住游戏）
static func load_all() -> Dictionary:
	var data := {"version": FORMAT_VERSION, "levels": {}}
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
	data["levels"] = levels
	return data

# 写回进度（先写临时文件再替换，避免中途崩坏把存档写坏）
static func save_all(data: Dictionary) -> void:
	var out := {"version": FORMAT_VERSION, "levels": data.get("levels", {})}
	var tmp := store_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	# Godot 的 FileAccess 没有 rename，用绝对路径 API 覆盖（对 user:// 与 res:// 都适用）
	if FileAccess.file_exists(store_path):
		DirAccess.remove_absolute(store_path)
	DirAccess.rename_absolute(tmp, store_path)

static func get_record(level_id: String) -> Dictionary:
	var all := load_all()
	var levels: Dictionary = all.get("levels", {})
	return levels.get(level_id, {}).duplicate()

# 该关最高星级（0 = 没通关）
static func best_stars(level_id: String) -> int:
	return int(get_record(level_id).get("stars", 0))

static func best_time(level_id: String) -> float:
	return float(get_record(level_id).get("best_time", 0.0))

static func is_cleared(level_id: String) -> bool:
	return best_stars(level_id) > 0

# 关卡是否解锁：第一关永远解锁，其余需要上一关已通关
static func is_unlocked(level_id: String) -> bool:
	var data := preload("res://scripts/data/CampaignData.gd")
	var order: int = int(data.level_order(level_id))
	if order <= 0:
		return true
	var prev: String = String(data.playable_levels()[order - 1].get("id", ""))
	return is_cleared(prev)

# 通关后记录成绩（只升不降：星级取高、用时取短）
static func record_win(level_id: String, stars: int, elapsed: float) -> void:
	var all := load_all()
	var levels: Dictionary = all.get("levels", {})
	var rec: Dictionary = levels.get(level_id, {})
	var old_stars := int(rec.get("stars", 0))
	var old_time := float(rec.get("best_time", 0.0))
	rec["stars"] = maxi(old_stars, stars)
	if old_time <= 0.0 or elapsed < old_time:
		rec["best_time"] = elapsed
	levels[level_id] = rec
	all["levels"] = levels
	save_all(all)

# 全部关卡星级合计（选关界面顶部显示）
static func total_stars() -> int:
	var data := preload("res://scripts/data/CampaignData.gd")
	var sum := 0
	for lv in data.playable_levels():
		sum += best_stars(String(lv.get("id", "")))
	return sum

# 重置全部进度（调试/玩家重玩用）
static func reset_all() -> void:
	if FileAccess.file_exists(store_path):
		DirAccess.remove_absolute(store_path)
