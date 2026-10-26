# scripts/core/WebTunnel.gd
# PC 主机开网页房时，用 Cloudflare Quick Tunnel 把本机 WebSocket 端口暴露成公网 wss://。
# 浏览器只能加入、不能监听端口，所以网页房必须由 PC/服务器端开一个隧道。
#
# cloudflared.exe 优先从这些位置查找：
#   1. 游戏 exe 同目录（Windows 发布包会带上）
#   2. 项目根目录（编辑器运行）
#   3. user://cloudflared.exe（手动下载后放这里也可以）
extends Node

signal tunnel_ready(wss_url: String, share_url: String)
signal tunnel_failed(reason: String)
signal tunnel_stopped()

const DOWNLOAD_URL: String = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
const WEB_ENTRY_URL: String = "https://fingerempire.netlify.app/"
const START_TIMEOUT_MS: int = 45000
const TUNNEL_HOST_RE: String = "https://([a-z0-9-]+\\.trycloudflare\\.com)"

var wss_url: String = ""
var share_url: String = ""
var running: bool = false
var last_error: String = ""

var _pid: int = -1
var _port: int = 8080
var _started_ms: int = 0
var _settled: bool = false
var _log_path: String = ""
var _bat_path: String = ""

func _ready() -> void:
	set_process(false)

# 是否找到可用的 cloudflared 可执行文件
func is_available() -> bool:
	return _find_binary() != ""

func _find_binary() -> String:
	var exe_name := "cloudflared.exe" if OS.get_name() == "Windows" else "cloudflared"
	var candidates: Array[String] = []
	var env_path := OS.get_environment("CLOUDFLARED_PATH").strip_edges()
	if env_path != "":
		candidates.append(env_path)
	# 发布包：cloudflared.exe 与 FingerEmpire.exe 同目录
	candidates.append(OS.get_executable_path().get_base_dir().path_join(exe_name))
	# 编辑器：项目根目录或 tools/ 下
	candidates.append(ProjectSettings.globalize_path("res://" + exe_name))
	candidates.append(ProjectSettings.globalize_path("res://tools/" + exe_name))
	# 兜底：用户手动放到 user:// 目录
	candidates.append(ProjectSettings.globalize_path("user://" + exe_name))
	for p in candidates:
		if p.strip_edges() != "" and FileAccess.file_exists(p):
			return p
	return ""

func binary_hint() -> String:
	var found := _find_binary()
	if found != "":
		return found
	return "未找到 cloudflared.exe，请重新下载完整 Windows 包，或把它放到游戏 exe 同目录"

func download_url() -> String:
	return DOWNLOAD_URL

# 启动一个 quick tunnel，把 http://127.0.0.1:<port> 映射成 https://xxxx.trycloudflare.com。
# 返回 false 表示启动失败；失败原因通过 tunnel_failed 信号发出，同时写入 last_error。
func start(port: int = 8080) -> bool:
	if running:
		return true
	var exe := _find_binary()
	if exe == "":
		_fail("未找到 cloudflared.exe。请重新下载完整 Windows 包，或把 cloudflared.exe 放到游戏 exe 同目录。")
		return false

	_port = port
	wss_url = ""
	share_url = ""
	last_error = ""
	_settled = false
	_started_ms = Time.get_ticks_msec()
	_log_path = ProjectSettings.globalize_path("user://web_tunnel.log")
	_bat_path = ProjectSettings.globalize_path("user://web_tunnel.bat")

	# 清空上一次日志，避免读到旧 URL
	var log_file := FileAccess.open(_log_path, FileAccess.WRITE)
	if log_file == null:
		_fail("无法创建隧道日志文件: " + _log_path)
		return false
	log_file.close()

	var bat := FileAccess.open(_bat_path, FileAccess.WRITE)
	if bat == null:
		_fail("无法创建隧道启动脚本: " + _bat_path)
		return false
	# cmd 的 > 重定向会把 cloudflared 的 stderr 横幅（含 quick tunnel URL）一起写进日志
	bat.store_string("@echo off\r\n\"%s\" tunnel --url http://127.0.0.1:%d --no-autoupdate > \"%s\" 2>&1\r\n" % [
		exe, _port, _log_path,
	])
	bat.close()

	_pid = OS.create_process("cmd.exe", ["/c", _bat_path])
	if _pid <= 0:
		_fail("启动 cloudflared 失败（create_process 返回 %d）" % _pid)
		return false

	running = true
	set_process(true)
	print("[WebTunnel] cloudflared 启动: pid=", _pid, " port=", _port)
	return true

func _process(_delta: float) -> void:
	if not running:
		return
	if not _settled:
		_poll()
	if not _settled and Time.get_ticks_msec() - _started_ms > START_TIMEOUT_MS:
		_fail("生成公网地址超时。请检查网络是否能访问 Cloudflare，或查看日志：" + _log_path)

func _poll() -> void:
	if FileAccess.file_exists(_log_path):
		var f := FileAccess.open(_log_path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var re := RegEx.new()
			if re.compile(TUNNEL_HOST_RE) == OK:
				var m := re.search(text)
				if m != null:
					var public_url: String = m.get_string(1)
					if public_url != "":
						wss_url = "wss://" + public_url
						share_url = WEB_ENTRY_URL + "?server=" + wss_url.uri_encode()
						_settled = true
						print("[WebTunnel] 网页房已就绪: ", wss_url)
						tunnel_ready.emit(wss_url, share_url)
						return
	if _pid > 0 and not OS.is_process_running(_pid):
		_fail("cloudflared 已退出，未能生成公网地址。\n" + _read_log_tail())

func _read_log_tail() -> String:
	if not FileAccess.file_exists(_log_path):
		return ""
	var f := FileAccess.open(_log_path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	text = text.strip_edges()
	if text.length() > 1200:
		text = text.substr(text.length() - 1200)
	return text

func _fail(reason: String) -> void:
	last_error = reason
	_settled = true
	running = false
	set_process(false)
	_kill_process()
	print("[WebTunnel] 失败: ", reason)
	tunnel_failed.emit(reason)

func _kill_process() -> void:
	if _pid <= 0:
		return
	if OS.get_name() == "Windows":
		var out: Array = []
		OS.execute("taskkill", ["/PID", str(_pid), "/T", "/F"], out, true)
	else:
		OS.kill(_pid)
	_pid = -1

# 关闭隧道。网页房依赖这个进程，游戏退出/主动停止时必须调用。
func stop() -> void:
	_kill_process()
	running = false
	_settled = false
	set_process(false)
	tunnel_stopped.emit()

func _exit_tree() -> void:
	if _pid > 0:
		stop()

func _notification(what: int) -> void:
	# 关闭游戏窗口时也要收掉 cloudflared 子进程，避免隧道在后台继续暴露服务器。
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
