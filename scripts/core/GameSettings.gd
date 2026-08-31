extends Node
enum AIDifficulty { EASY, NORMAL, HARD, HELL }
var player_nation: int = RTSConfig.Nation.VIKING
var enemy_nation: int = RTSConfig.Nation.ENGLAND
var ai_difficulty: int = AIDifficulty.EASY
var ai_mode: int = 1   # 单机模式：1=1V1, 2=2V2, 3=3V3（对称团队战，每方人数=模式值）
var blue_ai_difficulty: int = AIDifficulty.EASY  # 2v2 蓝方 AI
var red_ai_difficulty: int = AIDifficulty.EASY   # 2v2 红方 AI
var is_single_2v2: bool = false
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
enum CommandMode { SINGLE = 0, CONTINUOUS = 1 }
var command_mode: int = CommandMode.CONTINUOUS  # 单次/连续命令模式（_ready 中按平台设定）

var post_game_data: Dictionary = {}  # {power_history, player_is_blue} for results screen

func _ready() -> void:
	# 移动端默认单次命令（下令后取消选择），PC端默认连续命令
	if OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios"):
		command_mode = CommandMode.SINGLE
	update_ui_scale()
