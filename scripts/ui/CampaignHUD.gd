extends PanelContainer

# 战役任务面板：左上角常驻，显示关卡名、任务目标、进度与波次预警。
# 只负责显示，数据全部来自 CampaignDirector（导演每 0.2 秒刷新一次）。

const UIThemeScript = preload("res://scripts/ui/UITheme.gd")

var _title: Label = null
var _objective_box: VBoxContainer = null
var _progress: Label = null
var _warning: Label = null
var _director = null
var _last_signature := ""
var _mobile := false

func setup(director) -> void:
	_director = director

func _ready() -> void:
	name = "CampaignHUD"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mobile = InputSource.use_mobile_ui()
	var style := UIThemeScript.card_style(UIThemeScript.GOLD)
	style.content_margin_left = 12.0
	style.content_margin_right = 14.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 10.0
	add_theme_stylebox_override("panel", style)
	if _mobile:
		position = Vector2(UILayout.dp(8.0), UILayout.dp(112.0))
		custom_minimum_size = Vector2(UILayout.dp(250.0), 0.0)
	else:
		position = Vector2(16.0, 96.0)
		custom_minimum_size = Vector2(330.0, 0.0)
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4 if _mobile else 6)
	add_child(vb)
	_title = Label.new()
	UIThemeScript.apply_label(_title, UILayout.font_dp(11.0) if _mobile else UIThemeScript.FONT_MD, UIThemeScript.GOLD)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_title)
	_objective_box = VBoxContainer.new()
	_objective_box.add_theme_constant_override("separation", 2)
	vb.add_child(_objective_box)
	_progress = Label.new()
	UIThemeScript.apply_label(_progress, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_SM, UIThemeScript.PARCHMENT)
	_progress.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_progress)
	_warning = Label.new()
	UIThemeScript.apply_label(_warning, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_SM, UIThemeScript.VERMILION)
	_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning.visible = false
	vb.add_child(_warning)
	_refresh()

func _process(_delta: float) -> void:
	_refresh()

func _refresh() -> void:
	if _director == null or not is_instance_valid(_director):
		return
	var level: Dictionary = _director.level
	if level.is_empty():
		return
	var title_text := "⚔ " + str(level.get("name", ""))
	var objectives: Array = _director.objective_states
	var progress_text := str(_director.progress_text)
	var warning_text := str(_director.warning_text)
	var signature := title_text + "|" + str(objectives) + "|" + progress_text + "|" + warning_text
	if signature == _last_signature:
		return
	_last_signature = signature
	_title.text = title_text
	# 目标行按需重建（数量很少，重建比逐行比对简单）
	for child in _objective_box.get_children():
		child.queue_free()
	for item in objectives:
		var line := Label.new()
		var done := bool(item.get("done", false))
		var mark := "☑" if done else "◻"
		line.text = "%s %s" % [mark, str(item.get("label", ""))]
		var color: Color = UIThemeScript.EMERALD if done else UIThemeScript.PARCHMENT
		UIThemeScript.apply_label(line, UILayout.font_dp(10.0) if _mobile else UIThemeScript.FONT_SM, color)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_objective_box.add_child(line)
	_progress.text = progress_text
	_warning.text = warning_text
	_warning.visible = not warning_text.is_empty()
	# 面板宽度跟随内容，避免长文案被截
	reset_size()
