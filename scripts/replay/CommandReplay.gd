extends RefCounted

# 指令回放数据：只存“玩家下达了什么命令”，不存实体快照。
# 回放时用同一 sim_seed / 地图 / 设置重建对局，再按物理帧重演这些命令。

const VERSION: int = 1
const REPLAY_DIR: String = "user://replays"

var header: Dictionary = {}
var commands: Array = []

func setup_header(manager) -> void:
	var map_preset := ""
	var map: Node = manager.get_node_or_null("Map")
	if map != null:
		map_preset = String(map.get("preset_id")) if map.get("preset_id") != null else ""
	header = {
		"version": VERSION,
		"mode": "command",
		"created": Time.get_datetime_string_from_system(false, true),
		"sim_seed": int(GameSettings.sim_seed),
		"map_seed": int(GameSettings.map_seed),
		"map_id": String(GameSettings.map_id),
		"map_preset": map_preset,
		"player_nation": int(GameSettings.player_nation),
		"enemy_nation": int(GameSettings.enemy_nation),
		"ai_mode": int(GameSettings.ai_mode),
		"ai_difficulty": int(GameSettings.ai_difficulty),
		"blue_ai_difficulty": int(GameSettings.blue_ai_difficulty),
		"red_ai_difficulty": int(GameSettings.red_ai_difficulty),
		"is_ffa": bool(GameSettings.is_ffa),
		"ffa_nation_count": int(GameSettings.ffa_nation_count),
		"is_single_2v2": bool(GameSettings.is_single_2v2),
		"progression_mode": int(GameSettings.progression_mode),
		"fast_mode": bool(GameSettings.fast_mode),
		"duration": 0.0,
		"result": "",
		"command_count": 0,
	}

func add_command(tick: int, action: String, data: Dictionary) -> void:
	commands.append({"t": maxi(0, tick), "a": action, "d": data})

func to_dict() -> Dictionary:
	header["command_count"] = commands.size()
	return {"header": header, "commands": commands}

static func from_dict(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	var h: Dictionary = raw.get("header", {})
	if int(h.get("version", 0)) != VERSION:
		return {}
	var c: Array = raw.get("commands", [])
	return {"header": h, "commands": c}

static func _ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPLAY_DIR))

static func save_file(path: String, data: Dictionary) -> bool:
	_ensure_dir()
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()
	return true

static func load_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not parsed is Dictionary:
		return {}
	return from_dict(parsed)

static func new_path(header_data: Dictionary) -> String:
	_ensure_dir()
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var nation := int(header_data.get("player_nation", 0))
	return "%s/cmd_%s_n%d.cmdr" % [REPLAY_DIR, stamp, nation]
