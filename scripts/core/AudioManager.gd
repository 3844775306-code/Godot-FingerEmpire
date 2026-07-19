# AudioManager.gd — 全局音频管理 (Autoload)
extends Node

const SFX_POOL_SIZE = 10
var _music_player: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
var _sfx_index: int = 0
var _music_volume: float = 0.7
var _sfx_volume: float = 0.8
var _current_music: String = ""

# 音效路径映射
const SFX = {
	arrow_shoot   = "res://resources/audio/sound/arrow-shoot.wav",
	arrow_hit     = "res://resources/audio/sound/arrow_damage.wav",
	sword_swing   = "res://resources/audio/sound/basic-melee-swing.wav",
	heavy_swing   = "res://resources/audio/sound/strong-melee-swing.wav",
	sword_hit     = "res://resources/audio/sound/sword-hit.wav",
	cannon_fire   = "res://resources/audio/sound/cannon-fire.wav",
	cannon_hit    = "res://resources/audio/sound/cannon-on-hit.wav",
	treb_fire     = "res://resources/audio/sound/trebuchet_fire.wav",
	treb_hit      = "res://resources/audio/sound/trebuchet_hit.wav",
	unit_die      = "res://resources/audio/sound/die.wav",
	build_place   = "res://resources/audio/sound/place_build.wav",
	build_loop    = "res://resources/audio/sound/build-loop.wav",
	build_done    = "res://resources/audio/sound/build-finish.wav",
	produce       = "res://resources/audio/sound/build-finish.wav",
	upgrade_done  = "res://resources/audio/sound/upgrade-finish.wav",
	walk          = "res://resources/audio/sound/walk.wav",
	water_step    = "res://resources/audio/sound/step-into-water-puddle-wade.wav",
	swim          = "res://resources/audio/sound/swim.mp3",
	sail          = "res://resources/audio/sound/sail.mp3",
	ui_click      = "res://resources/audio/sound/mouse-click.wav",
	alert         = "res://resources/audio/sound/alert.wav",
	gather        = "res://resources/audio/sound/walk.wav",  # placeholder
}
const MUSIC = {
	menu    = "res://resources/audio/music/menu-music.wav",
	battle  = "res://resources/audio/music/epic_battle_music_1.mp3",
	victory = "res://resources/audio/music/victory-fanfare-8-bit-thunder-4.wav",
	defeat  = "res://resources/audio/music/defeat.wav",
}

func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Music player
	_music_player = AudioStreamPlayer.new()
	_music_player.bus = "Music" if AudioServer.get_bus_index("Music") != -1 else "Master"
	add_child(_music_player)
	# SFX pool
	for i in SFX_POOL_SIZE:
		var p = AudioStreamPlayer.new()
		p.bus = "SFX" if AudioServer.get_bus_index("SFX") != -1 else "Master"
		add_child(p)
		_sfx_pool.append(p)

func play_music(key: String):
	if key == _current_music: return
	_current_music = key
	var path = MUSIC.get(key, "")
	if path == "": return
	var stream = load(path)
	if not stream: return
	_music_player.stream = stream
	_music_player.volume_db = linear_to_db(_music_volume)
	_music_player.finished.connect(func(): _music_player.play(), CONNECT_ONE_SHOT)  # 循环播放
	_music_player.play()

func stop_music():
	_current_music = ""
	_music_player.stop()

func play_sfx(key: String):
	var path = SFX.get(key, "")
	if path == "" or not ResourceLoader.exists(path): return
	var p = _sfx_pool[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	p.stream = load(path)
	p.volume_db = linear_to_db(_sfx_volume)
	p.play()

func play_sfx_quiet(key: String):
	var path = SFX.get(key, "")
	if path == "" or not ResourceLoader.exists(path): return
	var p = _sfx_pool[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	p.stream = load(path)
	p.volume_db = linear_to_db(_sfx_volume * 0.3)
	p.play()

func play_sfx_3d(key: String, pos: Vector3, cam_pos: Vector3):
	# 距离衰减
	var dist = cam_pos.distance_to(pos)
	if dist > 50: return
	var path = SFX.get(key, "")
	if path == "": return
	var p = _sfx_pool[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	p.stream = load(path)
	var vol = _sfx_volume * clamp(1.0 - dist / 50.0, 0.1, 1.0)
	p.volume_db = linear_to_db(vol)
	p.play()

func set_music_volume(v: float):
	_music_volume = clamp(v, 0, 1)
	if _music_player: _music_player.volume_db = linear_to_db(_music_volume)

func set_sfx_volume(v: float):
	_sfx_volume = clamp(v, 0, 1)
