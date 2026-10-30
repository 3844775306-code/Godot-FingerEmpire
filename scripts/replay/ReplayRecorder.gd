extends Node
class_name ReplayRecorder

const ReplayStoreScript = preload("res://scripts/replay/ReplayStore.gd")
const AppVersionScript = preload("res://scripts/core/AppVersion.gd")

# 每秒 2.5 帧足够还原移动轨迹，回放端再做插值；文件体积也远小于逐帧。
const CAPTURE_INTERVAL: float = 0.4

var _manager: Node = null
var _header: Dictionary = {}
var _frames: Array = []
var _elapsed: float = 0.0
var _accum: float = 0.0
var _active: bool = false
var _saved: bool = false

func start(manager: Node) -> void:
	if _active:
		return
	_manager = manager
	_active = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	_header = {
		"version": 1,
		"interval": CAPTURE_INTERVAL,
		"duration": 0.0,
		"meta": _build_meta(),
		"map": _capture_map(),
	}
	_capture_frame()

func finish(reason: String = "对局结束") -> void:
	if not _active:
		return
	_active = false
	if is_inside_tree():
		_capture_frame()
	if _saved or _frames.is_empty():
		return
	_saved = true
	_header["duration"] = _elapsed
	_header["frame_count"] = _frames.size()
	var meta: Dictionary = _header.get("meta", {})
	meta["result"] = reason
	_header["meta"] = meta
	var path := ReplayStoreScript.new_path(meta)
	if ReplayStoreScript.save(path, _header, _frames):
		print("[录像] 已保存: ", path, "  时长 ", ReplayStoreScript.format_duration(_elapsed), "  帧数 ", _frames.size())
		ReplayStoreScript.prune(15)
	_frames.clear()

func _process(delta: float) -> void:
	if not _active:
		return
	if _manager == null or not is_instance_valid(_manager):
		finish("场景结束")
		return
	if bool(_manager.get("game_over")):
		finish("对局结束")
		return
	_elapsed += delta
	_accum += delta
	if _accum >= CAPTURE_INTERVAL:
		_accum = fmod(_accum, CAPTURE_INTERVAL)
		_capture_frame()

func _exit_tree() -> void:
	finish("中途退出")

func _build_meta() -> Dictionary:
	var map := _manager.get_node_or_null("Map")
	var preset: Dictionary = {}
	if map != null and map.get("map_preset") is Dictionary:
		preset = map.get("map_preset")
	var is_online := bool(_manager.get("is_online"))
	return {
		"created": Time.get_datetime_string_from_system(),
		"mode": "online" if is_online else "single",
		"map_id": String(GameSettings.map_id),
		"map_name": String(preset.get("name", GameSettings.map_id)),
		"map_seed": int(GameSettings.map_seed),
		"player_team": int(_manager.get("player_team")),
		"enemy_team": int(_manager.get("enemy_team")),
		"player_nation": int(GameSettings.player_nation),
		"game_version": AppVersionScript.version(),
	}

func _capture_map() -> Dictionary:
	var map := _manager.get_node_or_null("Map")
	if map == null:
		return {}
	var terrain = map.get("terrain_grid")
	var height = map.get("height_grid")
	if not (terrain is Array) or not (height is Array) or terrain.is_empty():
		return {}
	var overlay := _pack_overlay(map.get("overlay_grid"), terrain.size())
	var preset_id := String(GameSettings.map_id)
	var preset = map.get("map_preset")
	if preset is Dictionary and String(preset.get("id", "")) != "":
		preset_id = String(preset.get("id"))
	return {
		"terrain": terrain.duplicate(true),
		"height": height.duplicate(true),
		"overlay": overlay,
		"preset": preset_id,
	}

func _pack_overlay(grid, size: int) -> PackedByteArray:
	var packed := PackedByteArray()
	packed.resize(size * size)
	if not (grid is Array):
		return packed
	var i := 0
	for x in range(size):
		var row = grid[x] if x < grid.size() else null
		for y in range(size):
			var v := 0
			if row is Array and y < row.size():
				v = int(row[y])
			packed[i] = clampi(v, 0, 255)
			i += 1
	return packed

func _capture_frame() -> void:
	if not is_inside_tree():
		return
	var entities: Array = []
	for e in get_tree().get_nodes_in_group("entities"):
		if e == null or not is_instance_valid(e):
			continue
		var hp_value = e.get("health")
		var hp := float(hp_value) if hp_value != null else 1.0
		if hp <= 0.0:
			continue
		var lv_value = e.get("upgrade_level")
		var d := {
			"i": e.get_instance_id(),
			"e": int(e.get("entity_id")),
			"p": [e.global_position.x, e.global_position.y, e.global_position.z],
			"r": e.rotation.y,
			"lv": int(lv_value) if lv_value != null else 1,
			"c": bool(e.get_meta("_wall_is_corner", false)),
			"ruin": int(e.get("entity_id")) == 27 and int(e.get("team")) == RTSConfig.Team.NEUTRAL,
		}
		var color: Color = _manager.get_entity_color(e)
		d["col"] = [color.r, color.g, color.b]
		var model = e.get_meta("_model_instance") if e.has_meta("_model_instance") else null
		if model is Node3D:
			d["mp"] = String(model.scene_file_path)
			d["mo"] = [model.position.x, model.position.y, model.position.z]
			d["mr"] = [model.rotation.x, model.rotation.y, model.rotation.z]
			d["ms"] = [model.scale.x, model.scale.y, model.scale.z]
		entities.append(d)
	_frames.append({"t": snappedf(_elapsed, 0.01), "e": entities})
