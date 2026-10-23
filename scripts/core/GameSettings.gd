extends Node
enum AIDifficulty { EASY, NORMAL, HARD, HELL }
var player_nation: int = RTSConfig.Nation.VIKING
var enemy_nation: int = RTSConfig.Nation.ENGLAND
var ai_difficulty: int = AIDifficulty.EASY
var ai_mode: int = 1   # 单机模式：1=1V1, 2=2V2, 3=3V3（对称团队战，每方人数=模式值）
var blue_ai_difficulty: int = AIDifficulty.EASY  # 2v2 蓝方 AI
var red_ai_difficulty: int = AIDifficulty.EASY   # 2v2 红方 AI
var is_single_2v2: bool = false
var is_ffa: bool = false           # 单机乱斗模式：N国自由结盟/进贡/决裂/背叛
var ffa_nation_count: int = 3      # 乱斗模式总国家数（3-5）
# UI scaling for mobile
const DESIGN_WIDTH: int = 1920
const DESIGN_HEIGHT: int = 1080
static var ui_scale: float = 1.0
static var ui_offset_x: float = 0.0
static var ui_offset_y: float = 0.0

func update_ui_scale():
	var vp = get_viewport()
	if vp:
		var vs = vp.get_visible_rect().size
		ui_scale = min(vs.x / DESIGN_WIDTH, vs.y / DESIGN_HEIGHT)
		ui_offset_x = (vs.x - DESIGN_WIDTH * ui_scale) / 2.0
		ui_offset_y = (vs.y - DESIGN_HEIGHT * ui_scale) / 2.0

var fast_mode: bool = false  # 3x gather speed
var map_id: String = "classic"     # 地图预设（见 scripts/map/MapPresets.gd）
var map_seed: int = 0              # 0 = 随机；非 0 可复现同一张图
enum CommandMode { SINGLE = 0, CONTINUOUS = 1 }
var command_mode: int = CommandMode.CONTINUOUS  # 单次/连续命令模式（_ready 中按平台设定）

var post_game_data: Dictionary = {}  # {power_history, player_is_blue} for results screen

func _ready() -> void:
	# 调试构建支持命令行指定地图与模式：godot ... -- --map=ford --mode=2v2（导出包不生效）
	if OS.is_debug_build():
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--map="):
				map_id = a.substr(6)
			elif a.begins_with("--mode="):
				var m := a.substr(7)
				is_ffa = false
				match m:
					"2v2":
						ai_mode = 2
					"3v3":
						ai_mode = 3
					"ffa3", "ffa4", "ffa5":
						is_ffa = true
						ffa_nation_count = int(m.substr(3))
						ai_mode = 1
					_:
						ai_mode = 1
			elif a == "--mobile-ui":
				# 桌面端强制预览移动版 UI：godot ... -- --mobile-ui
				InputSource.force_mobile_ui = true
	# 移动端默认单次命令（下令后取消选择），PC端默认连续命令
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"):
		command_mode = CommandMode.SINGLE
	update_ui_scale()
