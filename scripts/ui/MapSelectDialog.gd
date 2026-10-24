# 战场地形卡片选择弹层：主菜单与联机大厅共用。
# 直接 new() 后 add_child() 即可弹出；点卡片发出 map_selected 并自行关闭。
extends Control

signal map_selected(id: String)

const MapPresets = preload("res://scripts/map/MapPresets.gd")
const MapPreview = preload("res://scripts/map/MapPreview.gd")

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 延后一帧再建：_ready 时视口可能还没按 stretch 规则算出真实尺寸
	call_deferred("_build")

func _build() -> void:
	var mobile := InputSource.use_mobile_ui()
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed:
			queue_free())
	add_child(dim)

	var ids: Array = MapPresets.all_ids()
	var vp := get_viewport_rect().size
	var panel_w: float = 0.0
	var panel_h: float = 0.0
	var header_h := 104.0
	var footer_h := 24.0
	var gap := 20.0
	var per_row := 4
	var card_w := 400.0
	var card_h := 400.0

	if mobile:
		# 手机：尺寸全部走 dp、字号走 font_dp；卡片数量多（二十多张），中段用 ScrollContainer 竖向滚动，
		# 否则固定高度下每张卡只能分到很扁的一条，字再大也看不清。
		gap = UILayout.dp(8.0)
		header_h = UILayout.dp(52.0)
		footer_h = UILayout.dp(8.0)
		# 竖屏三列、横屏四列
		per_row = 3 if vp.y >= vp.x else 4
		var rows: int = int(ceil(float(ids.size()) / float(per_row)))
		var max_w: float = minf(UILayout.dp(372.0), vp.x - UILayout.dp(8.0))
		var max_h: float = vp.y - UILayout.dp(6.0)
		card_w = (max_w - UILayout.dp(8.0) - float(per_row - 1) * gap) / float(per_row)
		card_h = UILayout.dp(120.0)
		var content_h: float = UILayout.dp(8.0) + float(rows) * card_h + float(rows - 1) * gap
		panel_w = max_w
		panel_h = minf(header_h + content_h + footer_h, max_h)
	else:
		# 桌面：先按可用高度定"最多几行"，再据此决定每行张数与卡宽，
		# 卡片内容按 400 高设计，高度不足时整体缩小，保证整块面板不溢出视口
		var max_panel_w := minf(1720.0, vp.x - 60.0)
		var max_panel_h := maxf(520.0, vp.y - 24.0)
		var rows: int = int(ceil(float(ids.size()) / float(per_row)))
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
		panel_w = float(per_row) * card_w + float(per_row - 1) * gap
		panel_h = header_h + float(rows) * card_h + float(rows - 1) * gap + footer_h

	var panel = Panel.new()
	var panel_pos_y: float = maxf(0.0, (vp.y - panel_h) * 0.5) if mobile else maxf(16.0, (vp.y - panel_h) * 0.5)
	panel.position = Vector2(maxf(0.0, (vp.x - panel_w) * 0.5), panel_pos_y)
	panel.size = Vector2(panel_w, panel_h)
	panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(panel)
	UITheme.fade_in(panel, 0.2)

	var fs_title: int = UILayout.font_dp(17.0) if mobile else 32
	var fs_hint: int = UILayout.font_dp(9.0) if mobile else 18
	var title = Label.new()
	title.text = "⚔️ 选择战场地形 ⚔️"
	title.position = Vector2(0, UILayout.dp(5.0) if mobile else 16)
	title.size = Vector2(panel_w, UILayout.dp(22.0) if mobile else 46)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(title, fs_title, UITheme.GOLD)
	panel.add_child(title)

	var hint = Label.new()
	hint.text = "特殊地形支持 1V1 / 2V2 / 3V3；地形会改变视野、移速与资源分布"
	hint.position = Vector2(0, UILayout.dp(27.0) if mobile else 66)
	hint.size = Vector2(panel_w, UILayout.dp(18.0) if mobile else 26)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(hint, fs_hint, UITheme.STONE.lightened(0.35))
	panel.add_child(hint)

	if mobile:
		# 中段卡片区可滚动（二十多张卡在竖屏一屏放不下）
		var scroll := ScrollContainer.new()
		scroll.position = Vector2(UILayout.dp(4.0), header_h)
		scroll.size = Vector2(panel_w - UILayout.dp(8.0), maxf(UILayout.dp(60.0), panel_h - header_h - footer_h))
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		panel.add_child(scroll)
		var grid := GridContainer.new()
		grid.columns = per_row
		grid.add_theme_constant_override("h_separation", int(gap))
		grid.add_theme_constant_override("v_separation", int(gap))
		scroll.add_child(grid)
		for i in range(ids.size()):
			var card = _make_map_card(String(ids[i]), Vector2.ZERO, Vector2(card_w, card_h))
			card.custom_minimum_size = Vector2(card_w, card_h)
			grid.add_child(card)
	else:
		var start_x := (panel_w - float(per_row) * card_w - float(per_row - 1) * gap) * 0.5
		for i in range(ids.size()):
			var col := i % per_row
			var row: int = int(i / per_row)
			var pos := Vector2(start_x + float(col) * (card_w + gap), header_h + float(row) * (card_h + gap))
			panel.add_child(_make_map_card(String(ids[i]), pos, Vector2(card_w, card_h)))

	var close = Button.new()
	close.text = "✕"
	var close_sz: float = UILayout.dp(34.0) if mobile else 44.0
	close.position = Vector2(panel_w - close_sz - (UILayout.dp(4.0) if mobile else 16.0), UILayout.dp(4.0) if mobile else 16)
	close.size = Vector2(close_sz, close_sz)
	UITheme.apply_muted_button(close, UILayout.font_dp(12.0) if mobile else 20)
	close.pressed.connect(func(): queue_free())
	panel.add_child(close)

func _make_map_card(id: String, pos: Vector2, card_size: Vector2) -> Control:
	var mobile := InputSource.use_mobile_ui()
	var card_id := id
	var info := MapPresets.get_info(id)
	var selected := id == GameSettings.map_id
	var cw := card_size.x
	var thumb_size := minf(cw - 100.0, 200.0)
	var fs_name := 24
	var fs_battle := 16
	var fs_chips := 15
	var fs_desc := 14
	var pad := 10.0
	var thumb_top := 14.0
	var name_h := 34.0
	var battle_h := 24.0
	var chips_h := 46.0
	if mobile:
		# 手机：缩略图占卡片上半部分，下面文字依次排开，字号全部按 dp 换算
		thumb_size = minf(cw - UILayout.dp(18.0), card_size.y * 0.42)
		fs_name = UILayout.font_dp(10.5)
		fs_battle = UILayout.font_dp(7.5)
		fs_chips = UILayout.font_dp(6.5)
		fs_desc = UILayout.font_dp(6.0)
		pad = UILayout.dp(5.0)
		thumb_top = UILayout.dp(5.0)
		name_h = UILayout.dp(12.0)
		battle_h = UILayout.dp(8.0)
		chips_h = UILayout.dp(13.0)

	var card = Panel.new()
	card.position = pos
	card.size = card_size
	card.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD if selected else UITheme.STONE))

	var thumb = TextureRect.new()
	thumb.position = Vector2((cw - thumb_size) * 0.5, thumb_top)
	thumb.size = Vector2(thumb_size, thumb_size)
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture = MapPreview.get_texture(id, int(thumb_size))
	card.add_child(thumb)

	var y := thumb_top + thumb_size + (UILayout.dp(4.0) if mobile else 10.0)

	var name_lbl = Label.new()
	name_lbl.text = String(info["name"])
	name_lbl.clip_text = true
	name_lbl.position = Vector2(pad, y)
	name_lbl.size = Vector2(cw - pad * 2.0, name_h)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(name_lbl, fs_name, UITheme.GOLD if selected else UITheme.PARCHMENT)
	card.add_child(name_lbl)
	y += name_h

	var battle_lbl = Label.new()
	battle_lbl.text = String(info["battle"])
	battle_lbl.clip_text = true
	battle_lbl.position = Vector2(pad, y)
	battle_lbl.size = Vector2(cw - pad * 2.0, battle_h)
	battle_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UITheme.apply_label(battle_lbl, fs_battle, UITheme.STONE.lightened(0.4))
	card.add_child(battle_lbl)
	y += battle_h

	var chips = Label.new()
	var chip_arr := PackedStringArray(info["chips"])
	chips.text = " · ".join(chip_arr)
	chips.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	chips.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chips.clip_text = true
	UITheme.apply_label(chips, fs_chips, UITheme.GOLD)
	# 先入树再定尺寸：自动换行标签在入树前算出的宽度会按整行文本撑开，窄卡时会溢出
	card.add_child(chips)
	chips.position = Vector2(pad, y)
	chips.size = Vector2(cw - pad * 2.0, chips_h)
	y += chips_h

	var desc = Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.clip_text = true   # 窄卡时允许裁字，避免自动换行把最小高度顶出卡片
	desc.text = String(info["desc"])
	UITheme.apply_label(desc, fs_desc, UITheme.PARCHMENT.darkened(0.15))
	# 先入树再定尺寸：自动换行标签在入树前算出的宽度会按整行文本撑开
	card.add_child(desc)
	desc.position = Vector2(pad, y)
	desc.size = Vector2(cw - pad * 2.0, maxf(0.0, card_size.y - y - (UILayout.dp(4.0) if mobile else 12.0)))

	var pick = Button.new()
	pick.flat = true
	pick.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pick.pressed.connect(func():
		map_selected.emit(card_id)
		queue_free())
	card.add_child(pick)
	return card
