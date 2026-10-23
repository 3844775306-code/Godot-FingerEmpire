# 战场地形卡片选择弹层：主菜单与联机大厅共用。
# 直接 new() 后 add_child() 即可弹出；点卡片发出 map_selected 并自行关闭。
extends Control

signal map_selected(id: String)

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapPreview = preload("res://scripts/map/MapPreview.gd")

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()

func _build() -> void:
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			queue_free())
	add_child(dim)

	var panel = Panel.new()
	# 卡片数量随预设增加：先按可用高度定"最多几行"，再据此决定每行张数与卡宽，
	# 卡片内容按 400 高设计，高度不足时整体缩小，保证整块面板不溢出视口
	var ids: Array = MapPresets.all_ids()
	var gap := 20.0
	var vp := get_viewport_rect().size
	var max_panel_w := minf(1720.0, vp.x - 60.0)
	var max_panel_h := maxf(520.0, vp.y - 24.0)
	var per_row := 4
	var rows := int(ceil(float(ids.size()) / float(per_row)))
	var card_h := 400.0
	var card_w := 400.0
	var found := false
	while card_h >= 240.0:
		var rows_max := maxi(1, int(floor((max_panel_h - 128.0 + gap) / (card_h + gap))))
		var pr := maxi(4, int(ceil(float(ids.size()) / float(rows_max))))
		var cw := (max_panel_w - float(pr - 1) * gap) / float(pr)
		if cw >= 130.0 and cw >= minf(card_h * 0.5, 300.0):
			per_row = pr
			rows = int(ceil(float(ids.size()) / float(per_row)))
			card_w = minf(400.0, cw)
			found = true
			break
		card_h -= 20.0
	if not found:
		per_row = 4
		rows = int(ceil(float(ids.size()) / float(per_row)))
		card_w = minf(400.0, (max_panel_w - float(per_row - 1) * gap) / float(per_row))
		card_h = 300.0
	var panel_w := float(per_row) * card_w + float(per_row - 1) * gap
	var panel_h := 104.0 + float(rows) * card_h + float(rows - 1) * gap + 24.0
	panel.position = Vector2(maxf(0.0, (vp.x - panel_w) * 0.5), maxf(16.0, (vp.y - panel_h) * 0.5))
	panel.size = Vector2(panel_w, panel_h)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.2)

	var title = Label.new()
	title.text = "⚔️ 选择战场地形 ⚔️"
	title.position = Vector2(0, 16)
	title.size = Vector2(panel_w, 46)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, 32, UITheme.GOLD)
	panel.add_child(title)

	var hint = Label.new()
	hint.text = "特殊地形支持 1V1 / 2V2 / 3V3；地形会改变视野、移速与资源分布"
	hint.position = Vector2(0, 66)
	hint.size = Vector2(panel_w, 26)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(hint, 18, UITheme.STONE.lightened(0.35))
	panel.add_child(hint)

	var row_w := float(per_row) * card_w + float(per_row - 1) * gap
	var start_x := (panel_w - row_w) * 0.5
	for i in range(ids.size()):
		var col := i % per_row
		var row := i / per_row
		var pos := Vector2(start_x + float(col) * (card_w + gap), 104.0 + float(row) * (card_h + gap))
		panel.add_child(_make_map_card(String(ids[i]), pos, Vector2(card_w, card_h)))

	var close = Button.new()
	close.text = "✕"
	close.position = Vector2(panel_w - 60.0, 16)
	close.size = Vector2(44, 44)
	UITheme.apply_muted_button(close, 20)
	close.pressed.connect(func(): queue_free())
	panel.add_child(close)

func _make_map_card(id: String, pos: Vector2, card_size: Vector2) -> Control:
	var card_id := id
	var info := MapPresets.get_info(id)
	var selected := id == GameSettings.map_id
	var cw := card_size.x
	var thumb_size := minf(cw - 100.0, 200.0)

	var card = Panel.new()
	card.position = pos
	card.size = card_size
	card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD if selected else UITheme.STONE))

	var thumb = TextureRect.new()
	thumb.position = Vector2((cw - thumb_size) * 0.5, 14)
	thumb.size = Vector2(thumb_size, thumb_size)
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = MapPreview.get_texture(id, int(thumb_size))
	card.add_child(thumb)

	var y := thumb_size + 24.0

	var name_lbl = Label.new()
	name_lbl.text = String(info["name"])
	name_lbl.clip_text = true
	name_lbl.position = Vector2(10, y)
	name_lbl.size = Vector2(cw - 20.0, 34)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(name_lbl, 24, UITheme.GOLD if selected else UITheme.PARCHMENT)
	card.add_child(name_lbl)
	y += 32.0

	var battle_lbl = Label.new()
	battle_lbl.text = String(info["battle"])
	battle_lbl.clip_text = true
	battle_lbl.position = Vector2(10, y)
	battle_lbl.size = Vector2(cw - 20.0, 24)
	battle_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(battle_lbl, 16, UITheme.STONE.lightened(0.4))
	card.add_child(battle_lbl)
	y += 26.0

	var chips = Label.new()
	var chip_arr := PackedStringArray(info["chips"])
	chips.text = " · ".join(chip_arr)
	chips.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chips.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chips.clip_text = true
	UITheme.apply_label(chips, 15, UITheme.GOLD)
	# 先入树再定尺寸：自动换行标签在入树前算出的宽度会按整行文本撑开，窄卡时会溢出
	card.add_child(chips)
	chips.position = Vector2(14, y)
	chips.size = Vector2(cw - 28.0, 46)
	y += 48.0

	var desc = Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.clip_text = true   # 窄卡时允许裁字，避免自动换行把最小高度顶出卡片
	desc.text = String(info["desc"])
	UITheme.apply_label(desc, 14, UITheme.PARCHMENT.darkened(0.15))
	# 先入树再定尺寸：自动换行标签在入树前算出的宽度会按整行文本撑开
	card.add_child(desc)
	desc.position = Vector2(16, y)
	desc.size = Vector2(cw - 32.0, card_size.y - y - 12.0)

	var pick = Button.new()
	pick.flat = true
	pick.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pick.pressed.connect(func():
		map_selected.emit(card_id)
		queue_free())
	card.add_child(pick)
	return card
