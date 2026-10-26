extends Node

enum GameState { MENU, PLAYING, GAME_OVER }
var current_state = GameState.MENU

# ==================== 功耗控制 ====================
# 之前整个项目没有任何帧率上限：Engine.max_fps 一直是 0（不限制），
# 能不能跑多快完全看显示器刷新率。在 120/144Hz 的屏幕或高刷手机上，
# 游戏就会一直以 120/144fps 渲染，GPU 满载——这是耗电最大的一项。
#
# RTS 画面本来就以静态地形和缓慢移动的单位为主，60fps 完全够用；
# 窗口失焦时更没有理由继续全速画，降到 15fps 可以省掉绝大部分 GPU 功耗。
const FPS_GAMEPLAY: int = 60
const FPS_IDLE: int = 15
# 画质档位对应的帧率上限：低功耗档连带帧率一起压，才真正省电
const FPS_BY_QUALITY: Array = [30, 45, 60, 90]

var _base_fps: int = FPS_GAMEPLAY
var _window_focused: bool = true
var _focus_poll: float = 0.0

func _ready():
	# 以窗口系统的真实状态为准：只靠 FOCUS 通知不够可靠，
	# 无边框窗口、嵌入窗口或远程桌面下可能收不到 FOCUS_IN，
	# 那样游戏会永远卡在闲置帧率上。
	_window_focused = DisplayServer.window_is_focused()
	_apply_fps(FPS_GAMEPLAY)
	# 网页邀请链接 / ?server=wss://...：启动后直接进联机大厅，省掉一次主菜单点击。
	if OS.has_feature("web") and _has_web_room_param():
		call_deferred("_open_web_room_lobby")
		return
	# 客户端模式下不自动切换场景
	if NetworkManager.mode == NetworkManager.Mode.CLIENT:
		return
	# 延迟到下一帧切换，避免场景树忙
	call_deferred("change_state", GameState.MENU)

func _has_web_room_param() -> bool:
	var js = Engine.get_singleton("JavaScriptBridge")
	if js == null:
		return false
	return String(js.eval("new URLSearchParams(location.search).get('server') || ''")).strip_edges() != ""

func _open_web_room_lobby() -> void:
	await get_tree().create_timer(0.1).timeout
	if is_inside_tree():
		get_tree().change_scene_to_file("res://scenes/online_menu.tscn")

func _process(delta: float) -> void:
	# 每 0.5 秒核对一次窗口焦点，作为通知机制之外的兜底
	_focus_poll -= delta
	if _focus_poll > 0.0:
		return
	_focus_poll = 0.5
	var focused: bool = DisplayServer.window_is_focused()
	if focused != _window_focused:
		_window_focused = focused
		_apply_fps(_base_fps)

# 画质档位联动帧率。level: 0=低功耗 1=低 2=中 3=高
func set_quality_fps(level: int) -> void:
	var idx: int = clampi(level, 0, FPS_BY_QUALITY.size() - 1)
	_base_fps = int(FPS_BY_QUALITY[idx])
	_apply_fps(_base_fps)

func _apply_fps(fps: int) -> void:
	# 失焦期间始终用闲置帧率，重新获得焦点后再恢复
	Engine.max_fps = FPS_IDLE if not _window_focused else fps

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED:
			_window_focused = false
			_apply_fps(_base_fps)
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_APPLICATION_RESUMED:
			_window_focused = true
			_apply_fps(_base_fps)

func change_state(new_state: int):
	current_state = new_state
	match new_state:
		GameState.MENU:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")   # 确保路径正确
		GameState.PLAYING:
			get_tree().change_scene_to_file("res://scenes/rts_battle.tscn")
