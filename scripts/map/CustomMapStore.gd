class_name CustomMapStore
extends RefCounted

# 自定义地图的本地存储与分享码。
# 地图本体是一个 JSON 字典；分享码 = gzip(JSON) 的 Base64，可直接粘贴给其他玩家。
# Web 版没有可用的系统文件选择器，所以分享优先使用文本码；本地存档放 user://。

const DIR := "user://custom_maps"
const SHARE_PREFIX := "FEMAP1:"
const FORMAT_VERSION := 1
const MAX_SHARE_BYTES := 16 * 1024 * 1024

static func maps_dir() -> String:
	return DIR

static func ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		DirAccess.make_dir_recursive_absolute(DIR)

static func _safe_name(name: String) -> String:
	var s := name.strip_edges()
	if s == "":
		s = "未命名地图"
	var out := ""
	for ch in s:
		if ch in "\\/:*?\"<>|":
			out += "_"
		else:
			out += ch
	out = out.strip_edges()
	if out == "":
		out = "未命名地图"
	return out

static func save_map(name: String, data: Dictionary) -> String:
	ensure_dir()
	var safe := _safe_name(name)
	var path := DIR + "/" + safe + ".json"
	var payload := data.duplicate(true)
	payload["name"] = name.strip_edges()
	payload["format"] = FORMAT_VERSION
	payload["updated"] = Time.get_datetime_string_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return path

static func load_map(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}

static func delete_map(path: String) -> bool:
	if path == "" or not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK

static func list_maps() -> Array:
	ensure_dir()
	var out: Array = []
	var dir := DirAccess.open(DIR)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var path := DIR + "/" + f
		var data := load_map(path)
		if data.is_empty():
			continue
		out.append({
			"path": path,
			"name": String(data.get("name", f.get_basename())),
			"updated": String(data.get("updated", "")),
		})
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out

# 地图数据必须能安全地交给 Ground 使用：正方形、行数一致、至少 16 格。
static func validate(data: Dictionary) -> String:
	var terrain = data.get("terrain", null)
	if not (terrain is Array) or terrain.size() < 16:
		return "地形数据为空或尺寸过小"
	var size: int = terrain.size()
	for col in terrain:
		if not (col is Array) or col.size() != size:
			return "地形网格不是正方形"
	var height = data.get("height", [])
	if height is Array and not height.is_empty():
		if height.size() != size:
			return "高度网格尺寸不匹配"
		for col in height:
			if not (col is Array) or col.size() != size:
				return "高度网格不是正方形"
	var castles = data.get("castles", [])
	if castles is Array and castles.size() >= 2:
		for c in castles:
			if not (c is Array) or c.size() < 2:
				return "城堡坐标格式错误"
			var cx := int(c[0])
			var cy := int(c[1])
			if cx < 0 or cy < 0 or cx >= size or cy >= size:
				return "城堡坐标超出地图范围"
	return ""

static func encode_share(data: Dictionary) -> String:
	var json := JSON.stringify(data)
	var raw := json.to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_GZIP)
	if packed.is_empty():
		packed = raw
	return SHARE_PREFIX + Marshalls.raw_to_base64(packed)

static func decode_share(code: String) -> Dictionary:
	var text := code.strip_edges()
	if text.begins_with(SHARE_PREFIX):
		text = text.substr(SHARE_PREFIX.length())
	if text == "":
		return {}
	var raw := Marshalls.base64_to_raw(text)
	if raw.is_empty():
		return {}
	var decompressed := raw.decompress_dynamic(MAX_SHARE_BYTES, FileAccess.COMPRESSION_GZIP)
	var json_bytes := decompressed if not decompressed.is_empty() else raw
	var parsed = JSON.parse_string(json_bytes.get_string_from_utf8())
	if parsed is Dictionary and validate(parsed) == "":
		return parsed
	return {}
