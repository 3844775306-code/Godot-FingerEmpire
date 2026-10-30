extends RefCounted
class_name ReplayStore

# 对局录像统一放在用户目录，导出/网页版都能持久化。
const DEFAULT_DIR: String = "user://replays"
const EXT: String = ".rep"
const MAGIC: String = "FINGER_EMPIRE_REPLAY_1"

# 可替换根目录：正常游戏使用 user://；自动化测试可指向工程内目录。
static var base_dir: String = DEFAULT_DIR

# 录像列表选中后由菜单写入，回放场景读取。
static var pending_path: String = ""

static func ensure_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(base_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)

static func new_path(meta: Dictionary) -> String:
	ensure_dir()
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var mode: String = String(meta.get("mode", "single"))
	var base := "replay_%04d%02d%02d_%02d%02d%02d_%s" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)), mode,
	]
	var path := base_dir.path_join(base + EXT)
	var n := 1
	while FileAccess.file_exists(path):
		path = base_dir.path_join("%s_%d%s" % [base, n, EXT])
		n += 1
	return path

static func save(path: String, header: Dictionary, frames: Array) -> bool:
	ensure_dir()
	# 快照里有大量重复字段和地图数组，ZSTD 压缩通常能把体积压到十分之一左右。
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("录像保存失败: " + path)
		return false
	f.store_line(MAGIC)
	f.store_var(header)
	f.store_var(frames)
	f.close()
	return true

static func _open_read(path: String) -> FileAccess:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		f = FileAccess.open(path, FileAccess.READ)
	return f

static func read_header(path: String) -> Dictionary:
	var f := _open_read(path)
	if f == null:
		return {}
	var magic := f.get_line()
	if magic != MAGIC:
		f.close()
		return {}
	var header = f.get_var()
	f.close()
	return header if header is Dictionary else {}

static func load_all(path: String) -> Dictionary:
	var f := _open_read(path)
	if f == null:
		return {}
	if f.get_line() != MAGIC:
		f.close()
		return {}
	var header = f.get_var()
	var frames = f.get_var()
	f.close()
	if not (header is Dictionary) or not (frames is Array):
		return {}
	return {"header": header, "frames": frames}

static func list_replays() -> Array:
	ensure_dir()
	var out: Array = []
	for file in DirAccess.get_files_at(base_dir):
		if not file.ends_with(EXT):
			continue
		var path := base_dir.path_join(file)
		var header := read_header(path)
		if header.is_empty():
			continue
		var meta: Dictionary = header.get("meta", {})
		var mtime := FileAccess.get_modified_time(path)
		out.append({
			"path": path,
			"file": file,
			"mtime": mtime,
			"date": format_datetime(mtime),
			"mode": String(meta.get("mode", "single")),
			"map_name": String(meta.get("map_name", "未知地图")),
			"duration": float(header.get("duration", 0.0)),
			"size": _file_size(path),
			"winner": String(meta.get("result", "")),
		})
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]))
	return out

static func latest_path() -> String:
	var list := list_replays()
	return String(list[0]["path"]) if not list.is_empty() else ""

static func prune(max_count: int = 30) -> void:
	var list := list_replays()
	for i in range(max_count, list.size()):
		delete_file(String(list[i]["path"]))

static func delete_file(path: String) -> bool:
	if path.begins_with(base_dir):
		return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
	return false

static func format_duration(seconds: float) -> String:
	var total := maxi(0, int(round(seconds)))
	return "%02d:%02d" % [total / 60, total % 60]

static func format_datetime(unix_time: int) -> String:
	if unix_time <= 0:
		return "未知时间"
	var dt := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%04d-%02d-%02d %02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)),
	]

static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size

static func format_size(bytes: int) -> String:
	if bytes >= 1024 * 1024:
		return "%.1f MB" % (float(bytes) / (1024.0 * 1024.0))
	return "%d KB" % maxi(1, bytes / 1024)
