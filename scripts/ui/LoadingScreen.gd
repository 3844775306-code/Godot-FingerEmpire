class_name LoadingScreen
extends Control

# 进场加载界面：异步加载目标场景，期间轮播对战预览图与底部小提示。
# 用法：LoadingScreen.goto_scene("res://scenes/rts_battle.tscn")

const MIN_SHOW_TIME: float = 1.0
const BACKGROUNDS: Array[Texture2D] = [
	preload("res://map_previews/bridge.png"),
	preload("res://map_previews/canyon.png"),
	preload("res://map_previews/coast.png"),
	preload("res://map_previews/desert.png"),
	preload("res://map_previews/fourislands.png"),
	preload("res://map_previews/marsh.png"),
	preload("res://map_previews/maze.png"),
	preload("res://map_previews/ring.png"),
	preload("res://map_previews/ruins_ingame.png"),
	preload("res://map_previews/loading_battle.png"),
	preload("res://map_previews/loading_mobile.png"),
	preload("res://map_previews/strait.png"),
	preload("res://map_previews/terrace.png"),
	preload("res://map_previews/tworivers.png"),
]
const TIPS: Array[String] = [
	"快捷键：T 打开科研树，H 切换收起/展开，F 快速定位主城。",
	"快捷键：Ctrl+数字 编队，数字 召回编队，空格 回到主城。",
	"采集优先级：食物和木材决定前期节奏，黄金留给关键科技和骑兵。",
	"建造中的建筑必须有农民站在旁边，进度才会推进。",
	"箭塔和城堡的射程受地形高低影响，占据高地更占便宜。",
	"骑兵适合骚扰补给线，长枪兵站定后对骑兵伤害极高。",
	"船只只能在水域建造和移动，注意桥面与浅滩的地形差别。",
	"科研模式：四个时代逐级解锁，升时代需要人口、建筑和资源。",
	"每个国家有 3 项特色科技，先看特色兵种再决定打法。",
	"攻城器械对建筑有加成，但怕骑兵贴脸，记得派兵护卫。",
	"森林会阻挡视线，也让单位更难被发现——适合伏击。",
	"把残血单位拉回主城附近可以慢慢回血，别白白送掉。",
	"粮草不足会降低生产速度，扩张前先确认食物收入。",
	"船只和运输船可以绕过地图上的河流与海湾，偷袭后方。",
	"3v3 中队友共享视野，善用信号标记集火目标。",
	"图标上的数字表示生产队列数量，批量生产能省下大量操作。",
]

static var target_scene: String = "res://scenes/rts_battle.tscn"
static var _wait_gate: Callable = Callable()
static var _wait_timeout: float = 0.0

static func goto_scene(path: String) -> void:
	_wait_gate = Callable()
	_wait_timeout = 0.0
	_start(path)

# 等 gate 返回 true 后再切场景；超时兜底，避免联机时房主被卡死在加载界面。
static func goto_scene_when(path: String, gate: Callable, timeout: float = 12.0) -> void:
	_start(path)
	_wait_gate = gate
	_wait_timeout = timeout

static func _start(path: String) -> void:
	target_scene = path
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	tree.change_scene_to_file("res://scenes/loading_screen.tscn")

@onready var _bg: TextureRect = $Background
@onready var _tip: Label = $Bottom/Tip
@onready var _progress: ProgressBar = $Bottom/Progress
var _elapsed: float = 0.0
var _tip_timer: float = 0.0
var _bg_timer: float = 0.0
var _tip_index: int = 0
var _bg_index: int = 0
var _fallback: bool = false
var _shown_frames: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Title.add_theme_font_size_override("font_size", 64)
	$Subtitle.add_theme_font_size_override("font_size", 24)
	_tip.add_theme_font_size_override("font_size", 22)
	_tip.add_theme_color_override("font_color", Color(0.94, 0.9, 0.82))
	_bg_index = randi() % BACKGROUNDS.size()
	_apply_background()
	_tip_index = randi() % TIPS.size()
	_tip.text = "💡 " + TIPS[_tip_index]
	_tip_timer = 4.0
	_bg_timer = 5.0
	if ResourceLoader.load_threaded_request(target_scene) != OK:
		# 客户端场景偶尔无法走线程加载；仍保留最短展示时间，避免直接黑屏跳场景。
		_fallback = true

func _apply_background() -> void:
	_bg.texture = BACKGROUNDS[_bg_index]
	_bg.modulate = Color(0.72, 0.72, 0.75, 1.0)

func _process(delta: float) -> void:
	_shown_frames += 1
	_elapsed += delta
	var progress: Array = []
	var status := ResourceLoader.THREAD_LOAD_FAILED if _fallback else ResourceLoader.load_threaded_get_status(target_scene, progress)
	_progress.value = clampf(float(progress[0]) if progress.size() > 0 else 0.0, 0.0, 1.0) * 100.0
	var can_enter := true
	if _wait_gate.is_valid() and _elapsed < _wait_timeout:
		can_enter = bool(_wait_gate.call())
	if status == ResourceLoader.THREAD_LOAD_LOADED and _elapsed >= MIN_SHOW_TIME and _shown_frames >= 2 and can_enter:
		var packed := ResourceLoader.load_threaded_get(target_scene) as PackedScene
		if packed:
			get_tree().change_scene_to_packed(packed)
		else:
			get_tree().change_scene_to_file(target_scene)
		set_process(false)
		return
	if (status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE) and _elapsed >= MIN_SHOW_TIME and _shown_frames >= 2:
		get_tree().change_scene_to_file(target_scene)
		set_process(false)
		return
	_tip_timer -= delta
	if _tip_timer <= 0.0:
		_tip_timer = 4.0
		_tip_index = (_tip_index + 1) % TIPS.size()
		_tip.text = "💡 " + TIPS[_tip_index]
	_bg_timer -= delta
	if _bg_timer <= 0.0:
		_bg_timer = 5.0
		_bg_index = (_bg_index + 1) % BACKGROUNDS.size()
		_apply_background()
