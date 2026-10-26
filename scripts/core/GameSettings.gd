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
var tutorial_mode: bool = false  # 新手教程对局：主菜单启动，进局后显示动态目标提示
var campaign_mode: bool = false      # 闯关模式：进局后由 CampaignDirector 接管开局生成与胜负判定
var campaign_level_id: String = ""   # 当前关卡 id（见 scripts/data/CampaignData.gd）
var map_id: String = "classic"     # 地图预设（见 scripts/map/MapPresets.gd）
var map_seed: int = 0              # 0 = 随机；非 0 可复现同一张图
enum CommandMode { SINGLE = 0, CONTINUOUS = 1 }
var command_mode: int = CommandMode.CONTINUOUS  # 单次/连续命令模式（_ready 中按平台设定）

# 手机端专用开关：没有键盘修饰键，用命令栏里的开关代替
var mobile_batch_produce: bool = false     # 批量生产：点生产按钮 = 电脑端 Ctrl+生产（同类型建筑一起产）
var mobile_continuous_build: bool = false  # 连续建造：放置完不退出建造模式 = 电脑端 Shift 连续建造
var mobile_gyro_rotate: bool = false       # 倾斜手机旋转视角（旧开关已移除），默认关闭；
										   # 现在手机端旋转视角用命令栏的「↻ 按住旋转」按钮

# 手机端双指手势固定为「缩放」：捏合缩放，拖动/扭转都不动视角。
# 旋转视角改由命令栏的「↻ 按住旋转」按钮控制（按住缓慢顺时针转，松手停）。

# ── 相机放大倍数（设置面板滑条）──
# 倍数越大 = 视野越近、单位看着越大、能看到的战场越少。
# 屏幕越小，同一片视野在眼里越小，所以默认值按设备区分：
#   电脑 1.00（最小）、iPad/平板 1.12、手机 1.25（最大）。
# 滑条范围故意收窄到 0.85~1.35，两端都还属于"看得舒服"的区间。
const CAMERA_ZOOM_MIN: float = 0.85
const CAMERA_ZOOM_MAX: float = 1.35
var camera_zoom_mult: float = 1.0

# 按设备给出相机放大倍数的默认值
static func default_camera_zoom_mult() -> float:
	# 桌面端用 -- --mobile-ui 预览时按手机处理，方便在电脑上验证手机默认值
	if InputSource.force_mobile_ui:
		return 1.25
	if not InputSource.is_mobile_platform():
		return 1.0
	# 手机和平板都算 mobile 平台，用窗口最小边区分：手机普遍 ≤1200px，平板 ≥1536px
	var win: Vector2i = DisplayServer.window_get_size()
	var min_side: int = mini(win.x, win.y)
	if min_side >= 1400:
		return 1.12
	return 1.25

var post_game_data: Dictionary = {}  # {power_history, player_is_blue} for results screen

# ==================== 战报接收筛选 ====================
# 战报类型。只有建造 / 升级 / 生产三类需要按国家过滤，
# 战斗、外交、经济这类与自己直接相关的消息始终接收。
enum AlertKind { COMBAT = 0, BUILD = 1, UPGRADE = 2, PRODUCE = 3, DIPLOMACY = 4, ECONOMY = 5, MISC = 6 }

# 默认不接收队友国家的建造 / 升级 / 生产战报（队友主城升级例外，始终接收）。
# 队友的这些动静与自己关系不大，全收会把战况栏刷满自己关心的战斗消息。
var alert_friendly_build: bool = false
var alert_friendly_upgrade: bool = false
var alert_friendly_produce: bool = false

# 单位血条文字：默认关闭，只保留血条色条；需要在设置面板手动打开。
# 单机 HUD 和联机 ClientRenderer 都读取这个开关。
var show_unit_text: bool = false

# 立即把血条文字开关同步到当前对局界面（设置面板勾选后无需重开）。
func set_unit_text_enabled(on: bool) -> void:
	show_unit_text = on
	for node in get_tree().get_nodes_in_group("game_hud"):
		if "show_unit_text" in node:
			node.set("show_unit_text", on)
	for node in get_tree().get_nodes_in_group("client_renderer"):
		if "show_unit_text" in node:
			node.set("show_unit_text", on)

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
	# 相机放大倍数按设备取默认值（必须在解析完 --mobile-ui 之后）
	camera_zoom_mult = default_camera_zoom_mult()
	update_ui_scale()
