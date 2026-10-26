class_name UpdateChecker
extends Node

# 更新检查器：拉一个静态 JSON 清单，比较版本号，判断有没有新版本可用。
#
# 用法：
#   var checker := UpdateChecker.new()
#   add_child(checker)
#   checker.finished.connect(_on_update_checked)
#   checker.check()          # 30 分钟内优先用缓存，不重复联网
#   checker.check(true)      # 强制联网（手动点「检查更新」时用）
#   checker.check(true, url) # 官方接口；测试或特殊部署时可临时指定清单地址
#
# 信号参数：ok（有没有成功拿到清单）、has_update、远端版本号、下载链接、更新说明
#
# 清单格式见 scripts/core/UpdateConfig.gd 顶部注释。

signal finished(ok: bool, has_update: bool, remote_version: String, download_url: String, notes: String)

const UpdateConfig = preload("res://scripts/core/UpdateConfig.gd")
const AppVersion = preload("res://scripts/core/AppVersion.gd")

const CACHE_PATH: String = "user://update_cache.json"

var _http: HTTPRequest = null
var _busy: bool = false
var _manifest_url: String = ""

func _ready() -> void:
	_ensure_http()

func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	_http.name = "Http"
	_http.timeout = UpdateConfig.TIMEOUT_SEC
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

func _exit_tree() -> void:
	_busy = false

# ==================== 对外接口 ====================
func check(force: bool = false, url_override: String = "") -> void:
	if not UpdateConfig.ENABLED:
		finished.emit(false, false, "", "", "更新检查已关闭")
		return
	var manifest_url: String = url_override.strip_edges()
	if manifest_url == "":
		manifest_url = UpdateConfig.manifest_url()
	if manifest_url == "":
		# 还没配置站点地址：静默跳过，不影响启动
		finished.emit(false, false, "", "", "未配置更新清单地址")
		return
	if _busy:
		return
	_manifest_url = manifest_url
	if not force:
		var cached := _read_cache()
		if not cached.is_empty():
			_emit_from_manifest(cached)
			return
	_ensure_http()
	_busy = true
	_start_request.call_deferred(manifest_url)

func _start_request(manifest_url: String) -> void:
	if _http == null:
		_busy = false
		finished.emit(false, false, "", "", "无法发起网络请求")
		return
	var err: int = _http.request(manifest_url)
	if err != OK:
		_busy = false
		finished.emit(false, false, "", "", "无法发起网络请求")

# ==================== 网络回调 ====================
func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		finished.emit(false, false, "", "", "检查更新失败（网络或服务器问题）")
		return
	var manifest: Dictionary = parse_manifest(body.get_string_from_utf8())
	if manifest.is_empty():
		finished.emit(false, false, "", "", "更新清单格式不正确")
		return
	_write_cache(manifest)
	_emit_from_manifest(manifest)

func _emit_from_manifest(manifest: Dictionary) -> void:
	var remote_version: String = String(manifest.get("version", ""))
	var has_update: bool = is_newer(remote_version, AppVersion.version())
	var url: String = download_url_for(manifest, _manifest_url)
	var notes: String = String(manifest.get("notes", ""))
	finished.emit(true, has_update, remote_version, url, notes)

# 把清单里的相对链接补成完整地址；清单和下载文件可以放在同一站点。
static func resolve_url(base_url: String, link: String) -> String:
	var target: String = String(link).strip_edges()
	if target == "":
		return ""
	var lower: String = target.to_lower()
	if lower.begins_with("http://") or lower.begins_with("https://"):
		return target
	var base: String = String(base_url).strip_edges()
	if base == "":
		return target
	if target.begins_with("//"):
		return ("http:" if base.begins_with("http://") else "https:") + target
	var scheme_end: int = base.find("://")
	if scheme_end < 0:
		return target
	if target.begins_with("/"):
		var host_end: int = base.find("/", scheme_end + 3)
		var origin: String = base.substr(0, host_end) if host_end >= 0 else base
		return origin + target
	var slash: int = base.rfind("/")
	if slash < 0:
		return target
	return base.substr(0, slash + 1) + target

# ==================== 版本号比较 ====================
# "v1.2.3" / "1.2.3" / "v1.2" → [1, 2, 3]，非法片段按 0 处理
static func parse_version(text: String) -> Array:
	var clean: String = String(text).strip_edges()
	if clean.begins_with("v") or clean.begins_with("V"):
		clean = clean.substr(1)
	var out: Array = []
	for part in clean.split(".", false):
		var digits: String = ""
		for i in part.length():
			var ch: String = part[i]
			if ch >= "0" and ch <= "9":
				digits += ch
			else:
				break
		out.append(int(digits) if digits != "" else 0)
	while out.size() < 3:
		out.append(0)
	return out

# 远端版本是否比本地新（相等不算新）
static func is_newer(remote: String, local: String) -> bool:
	var a: Array = parse_version(remote)
	var b: Array = parse_version(local)
	var n: int = maxi(a.size(), b.size())
	for i in n:
		var x: int = int(a[i]) if i < a.size() else 0
		var y: int = int(b[i]) if i < b.size() else 0
		if x != y:
			return x > y
	return false

# ==================== 清单解析 ====================
# 解析 JSON 文本，格式不对返回空字典（不抛错）
static func parse_manifest(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = json.data
	if String(data.get("version", "")).strip_edges() == "":
		return {}
	return data

# 当前平台在清单里的键名
static func platform_key() -> String:
	if OS.has_feature("android"):
		return "android"
	if OS.has_feature("web"):
		return "web"
	if OS.has_feature("windows"):
		return "windows"
	if OS.has_feature("macos"):
		return "macos"
	if OS.has_feature("linux"):
		return "linux"
	return "default"

# 按平台取下载链接，取不到就退回 default；相对链接按清单地址补全
static func download_url_for(manifest: Dictionary, base_url: String = "") -> String:
	var downloads = manifest.get("downloads", {})
	if typeof(downloads) != TYPE_DICTIONARY:
		return ""
	for key in [platform_key(), "default"]:
		var url: String = String(downloads.get(key, "")).strip_edges()
		if url != "":
			return resolve_url(base_url, url)
	return ""

# ==================== 缓存 ====================
func _read_cache() -> Dictionary:
	if UpdateConfig.CACHE_TTL_SEC <= 0:
		return {}
	if not FileAccess.file_exists(CACHE_PATH):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(CACHE_PATH)) != OK:
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = json.data
	var checked_at: int = int(data.get("checked_at", 0))
	var now: int = int(Time.get_unix_time_from_system())
	if now - checked_at > UpdateConfig.CACHE_TTL_SEC:
		return {}
	var manifest = data.get("manifest", {})
	if typeof(manifest) != TYPE_DICTIONARY:
		return {}
	return manifest

func _write_cache(manifest: Dictionary) -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		# 沙箱/只读环境写不了缓存：不影响本次结果，只是下次还会联网
		return
	f.store_string(JSON.stringify({
		"checked_at": int(Time.get_unix_time_from_system()),
		"manifest": manifest,
	}))
	f.close()
