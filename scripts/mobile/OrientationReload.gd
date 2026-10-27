class_name OrientationReload
extends Node

# 菜单类场景挂这个节点：手机横竖屏切换后重载当前场景。
# 重载是最稳的重排方式——菜单里有大量「构建时算好的 dp 尺寸/绝对坐标」，
# 只改 anchor 不会重新算字号和按钮高度。
#
# 注意：战斗场景绝对不能挂，重载会直接丢掉正在进行的对局；
# 战斗 HUD 由 ClientHUD 自己监听 size_changed 后重建 MobileHUD。

var _portrait: bool = false
var _reload_pending: bool = false

func _ready() -> void:
	if not InputSource.use_mobile_ui():
		return
	call_deferred("_bind_after_layout")

# 等首帧布局完成再记录方向，避免窗口还在从默认尺寸切到手机尺寸时误判为「旋转」。
# 再等 0.8 秒，覆盖 Web 首次计算出 canvas 尺寸的抖动（启动阶段绝不能再重载一次）。
func _bind_after_layout() -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(0.8).timeout
	if not is_inside_tree():
		return
	_portrait = UILayout.is_portrait()
	var vp := get_viewport()
	if vp != null:
		vp.size_changed.connect(_on_viewport_size_changed)

func _on_viewport_size_changed() -> void:
	if not InputSource.use_mobile_ui():
		return
	var now := UILayout.is_portrait()
	if now == _portrait:
		return
	_portrait = now
	if _reload_pending:
		return
	_reload_pending = true
	call_deferred("_reload_scene")

func _reload_scene() -> void:
	if not is_inside_tree():
		return
	print("[OrientationReload] 重载场景：portrait=", _portrait)
	get_tree().reload_current_scene()
