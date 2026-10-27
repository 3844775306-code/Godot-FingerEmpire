# scripts/ui/ResearchPanel.gd
# 科研模式主面板：时代、研究队列、9 类通用科技 + 本国 3 项特色科技。
# 右上「科研官」按钮打开智能科研官：设置分类优先级，自动研究科技与升级时代。
# 单机由 RTSBattleManager 提供状态；联机客户端由 ClientRenderer 的快照镜像提供，
# 面板只调用统一的 ui_research_* 接口，不直接改任何服务端状态。
class_name ResearchPanel
extends Control

const CARD_MIN := Vector2(430, 112)
const PANEL_SIZE := Vector2(1240, 780)
const CATEGORY_ALL := "ALL"

var source_node = null
var _selected_category: String = "A"
var _refresh_timer: float = 0.0
var _last_hash: String = ""

var _root_panel: Panel = null
var _age_label: Label = null
var _age_roman: Label = null
var _age_hint: Label = null
var _age_btn: Button = null
var _current_label: Label = null
var _progress: ProgressBar = null
var _cancel_btn: Button = null
var _foot_label: Label = null
var _scroll: ScrollContainer = null
var _grid: GridContainer = null
var _tab_buttons: Dictionary = {}
# 智能科研官
var _auto_btn: Button = null
var _auto_dim: ColorRect = null
var _auto_panel: Panel = null
var _auto_enable_check: CheckButton = null
var _auto_age_check: CheckButton = null
var _priority_rank_labels: Dictionary = {}
var _priority_up_buttons: Dictionary = {}
var _priority_down_buttons: Dictionary = {}
var _auto_foot: Label = null
var _syncing_auto_ui := false

static func open(host: Node, provider: Node = null) -> void:
	var existing := host.get_node_or_null("ResearchPanel")
	if existing != null:
		existing.queue_free()
		return
	var p := ResearchPanel.new()
	p.name = "ResearchPanel"
	p.source_node = provider if provider != null else host
	host.add_child(p)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 210
	_build_shell()
	_build_auto_panel()
	_rebuild()

func _build_shell() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.03, 0.04, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	_root_panel = Panel.new()
	_root_panel.size = PANEL_SIZE
	var vp_size := get_viewport_rect().size
	var panel_pos := (vp_size - PANEL_SIZE) * 0.5
	_root_panel.position = Vector2(maxf(panel_pos.x, 0.0), maxf(panel_pos.y, 0.0))
	_root_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	add_child(_root_panel)

	var title := Label.new()
	title.text = "🔬  科 研 树"
	title.position = Vector2(28, 16)
	title.size = Vector2(420, 40)
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", UITheme.GOLD)
	_root_panel.add_child(title)

	_age_roman = Label.new()
	_age_roman.position = Vector2(470, 12)
	_age_roman.size = Vector2(160, 48)
	_age_roman.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_age_roman.add_theme_font_size_override("font_size", 34)
	_age_roman.add_theme_color_override("font_color", UITheme.GOLD)
	_root_panel.add_child(_age_roman)

	_age_label = Label.new()
	_age_label.position = Vector2(620, 18)
	_age_label.size = Vector2(270, 36)
	_age_label.add_theme_font_size_override("font_size", 24)
	_age_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_root_panel.add_child(_age_label)

	_auto_btn = Button.new()
	_auto_btn.text = "⚙ 科研官"
	_auto_btn.position = Vector2(900, 16)
	_auto_btn.size = Vector2(158, 40)
	_auto_btn.tooltip_text = "打开智能科研官：设置科研分类优先级，自动研究科技与升级时代"
	UITheme.apply_muted_button(_auto_btn, 16)
	_auto_btn.pressed.connect(_toggle_auto_panel)
	_root_panel.add_child(_auto_btn)

	var close_btn := Button.new()
	close_btn.text = "✕ 关闭 (T)"
	close_btn.position = Vector2(1074, 16)
	close_btn.size = Vector2(140, 40)
	UITheme.apply_muted_button(close_btn, 17)
	close_btn.pressed.connect(queue_free)
	_root_panel.add_child(close_btn)

	_current_label = Label.new()
	_current_label.position = Vector2(28, 66)
	_current_label.size = Vector2(760, 30)
	_current_label.add_theme_font_size_override("font_size", 18)
	_current_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_root_panel.add_child(_current_label)

	_progress = ProgressBar.new()
	_progress.position = Vector2(28, 100)
	_progress.size = Vector2(900, 14)
	_progress.max_value = 100.0
	_progress.show_percentage = false
	_root_panel.add_child(_progress)

	_cancel_btn = Button.new()
	_cancel_btn.text = "取消研究"
	_cancel_btn.position = Vector2(946, 88)
	_cancel_btn.size = Vector2(130, 34)
	UITheme.apply_muted_button(_cancel_btn, 15)
	_cancel_btn.pressed.connect(_on_cancel_pressed)
	_root_panel.add_child(_cancel_btn)

	var sep := HSeparator.new()
	sep.position = Vector2(24, 132)
	sep.size = Vector2(1192, 2)
	_root_panel.add_child(sep)

	# 左侧：时代推进 + 分类
	var left := VBoxContainer.new()
	left.position = Vector2(24, 148)
	left.size = Vector2(248, 610)
	left.add_theme_constant_override("separation", 4)
	_root_panel.add_child(left)

	var age_title := Label.new()
	age_title.text = "时代推进"
	age_title.add_theme_font_size_override("font_size", 20)
	age_title.add_theme_color_override("font_color", UITheme.GOLD)
	left.add_child(age_title)

	_age_hint = Label.new()
	_age_hint.custom_minimum_size = Vector2(240, 120)
	_age_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_age_hint.add_theme_font_size_override("font_size", 14)
	_age_hint.add_theme_color_override("font_color", UITheme.PARCHMENT)
	left.add_child(_age_hint)

	_age_btn = Button.new()
	_age_btn.custom_minimum_size = Vector2(240, 42)
	UITheme.apply_muted_button(_age_btn, 16)
	_age_btn.pressed.connect(_on_age_pressed)
	left.add_child(_age_btn)

	var cat_title := Label.new()
	cat_title.text = "科技分类"
	cat_title.add_theme_font_size_override("font_size", 18)
	cat_title.add_theme_color_override("font_color", UITheme.GOLD)
	left.add_child(cat_title)

	for cat in TechTreeData.CATEGORIES:
		var cid := String(cat["id"])
		var b := Button.new()
		b.text = "%s  %s" % [cid, String(cat["name"])]
		b.custom_minimum_size = Vector2(240, 30)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		UITheme.apply_muted_button(b, 15)
		b.pressed.connect(_select_category.bind(cid))
		left.add_child(b)
		_tab_buttons[cid] = b
	var nb := Button.new()
	nb.text = "N  国家特色"
	nb.custom_minimum_size = Vector2(240, 32)
	nb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	UITheme.apply_muted_button(nb, 15)
	nb.pressed.connect(_select_category.bind("N"))
	left.add_child(nb)
	_tab_buttons["N"] = nb

	# 右侧：科技卡片滚动区
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(288, 148)
	_scroll.size = Vector2(928, 566)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root_panel.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)

	_foot_label = Label.new()
	_foot_label.position = Vector2(28, 730)
	_foot_label.size = Vector2(1180, 28)
	_foot_label.add_theme_font_size_override("font_size", 15)
	_foot_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_root_panel.add_child(_foot_label)

func _build_auto_panel() -> void:
	_auto_dim = ColorRect.new()
	_auto_dim.color = Color(0.02, 0.03, 0.04, 0.5)
	_auto_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_auto_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_auto_dim.z_index = 4
	_auto_dim.visible = false
	_root_panel.add_child(_auto_dim)

	_auto_panel = Panel.new()
	_auto_panel.name = "AutoResearchPanel"
	_auto_panel.size = Vector2(640, 650)
	_auto_panel.position = Vector2((PANEL_SIZE.x - _auto_panel.size.x) * 0.5, (PANEL_SIZE.y - _auto_panel.size.y) * 0.5)
	_auto_panel.z_index = 5
	_auto_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_auto_panel.add_theme_stylebox_override("panel", UITheme.card_style(UITheme.GOLD))
	_auto_panel.visible = false
	_root_panel.add_child(_auto_panel)

	var title := Label.new()
	title.text = "🧠  智能科研官"
	title.position = Vector2(24, 16)
	title.size = Vector2(420, 40)
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", UITheme.GOLD)
	_auto_panel.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "✕ 关闭"
	close_btn.position = Vector2(540, 14)
	close_btn.size = Vector2(76, 36)
	UITheme.apply_muted_button(close_btn, 15)
	close_btn.pressed.connect(_close_auto_panel)
	_auto_panel.add_child(close_btn)

	var desc := Label.new()
	desc.text = "开启后，科研官会按下方分类优先级自动选择下一项科技；时代升级条件满足时会优先升时代。\n人口/建筑条件未满足时，会先补能解锁所需建筑的科技。"
	desc.position = Vector2(24, 60)
	desc.size = Vector2(592, 52)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 15)
	desc.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_auto_panel.add_child(desc)

	_auto_enable_check = CheckButton.new()
	_auto_enable_check.text = "启用自动研究"
	_auto_enable_check.position = Vector2(24, 118)
	_auto_enable_check.size = Vector2(280, 34)
	_auto_enable_check.add_theme_font_size_override("font_size", 18)
	_auto_enable_check.add_theme_color_override("font_color", UITheme.GOLD)
	_auto_enable_check.toggled.connect(_on_auto_enabled_toggled)
	_auto_panel.add_child(_auto_enable_check)

	_auto_age_check = CheckButton.new()
	_auto_age_check.text = "自动升级时代"
	_auto_age_check.position = Vector2(320, 118)
	_auto_age_check.size = Vector2(280, 34)
	_auto_age_check.add_theme_font_size_override("font_size", 16)
	_auto_age_check.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_auto_age_check.toggled.connect(_on_auto_age_toggled)
	_auto_panel.add_child(_auto_age_check)

	var prio_title := Label.new()
	prio_title.text = "科研分类优先级"
	prio_title.position = Vector2(24, 160)
	prio_title.size = Vector2(260, 28)
	prio_title.add_theme_font_size_override("font_size", 20)
	prio_title.add_theme_color_override("font_color", UITheme.GOLD)
	_auto_panel.add_child(prio_title)

	var prio_hint := Label.new()
	prio_hint.text = "数字越小越优先，用 ▲▼ 调整；同类科技按时代、耗时依次研究。"
	prio_hint.position = Vector2(24, 190)
	prio_hint.size = Vector2(592, 26)
	prio_hint.add_theme_font_size_override("font_size", 14)
	prio_hint.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_auto_panel.add_child(prio_hint)

	var rows := VBoxContainer.new()
	rows.position = Vector2(24, 220)
	rows.size = Vector2(592, 360)
	rows.add_theme_constant_override("separation", 3)
	_auto_panel.add_child(rows)
	for cid in ResearchAdvisor.CATEGORY_IDS:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(592, 30)
		row.add_theme_constant_override("separation", 6)
		rows.add_child(row)

		var rank := Label.new()
		rank.custom_minimum_size = Vector2(30, 28)
		rank.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rank.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rank.add_theme_font_size_override("font_size", 18)
		rank.add_theme_color_override("font_color", UITheme.GOLD)
		row.add_child(rank)
		_priority_rank_labels[cid] = rank

		var cat_label := Label.new()
		cat_label.text = "%s  %s" % [String(cid), ResearchAdvisor.category_name(String(cid))]
		cat_label.custom_minimum_size = Vector2(408, 28)
		cat_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cat_label.add_theme_font_size_override("font_size", 16)
		cat_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
		row.add_child(cat_label)

		var up := Button.new()
		up.text = "▲ 提前"
		up.custom_minimum_size = Vector2(70, 28)
		UITheme.apply_muted_button(up, 13)
		up.pressed.connect(_on_priority_move.bind(String(cid), -1))
		row.add_child(up)
		_priority_up_buttons[cid] = up

		var down := Button.new()
		down.text = "▼ 延后"
		down.custom_minimum_size = Vector2(70, 28)
		UITheme.apply_muted_button(down, 13)
		down.pressed.connect(_on_priority_move.bind(String(cid), 1))
		row.add_child(down)
		_priority_down_buttons[cid] = down

	_auto_foot = Label.new()
	_auto_foot.position = Vector2(24, 598)
	_auto_foot.size = Vector2(592, 30)
	_auto_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_auto_foot.add_theme_font_size_override("font_size", 14)
	_auto_foot.add_theme_color_override("font_color", UITheme.PARCHMENT)
	_auto_panel.add_child(_auto_foot)

func _toggle_auto_panel() -> void:
	if _auto_panel == null:
		return
	_auto_panel.visible = not _auto_panel.visible
	if _auto_dim != null:
		_auto_dim.visible = _auto_panel.visible
	if _auto_panel.visible:
		_refresh_auto_ui()

func _close_auto_panel() -> void:
	if _auto_panel != null:
		_auto_panel.visible = false
	if _auto_dim != null:
		_auto_dim.visible = false

func _auto_config() -> Dictionary:
	var st := _state()
	if st.is_empty():
		return ResearchAdvisor.default_config()
	return ResearchAdvisor.normalize_config(st.get("auto", {}))

func _refresh_auto_ui() -> void:
	if _auto_panel == null or not _auto_panel.visible:
		return
	var cfg := _auto_config()
	_syncing_auto_ui = true
	_auto_enable_check.button_pressed = bool(cfg.get("enabled", false))
	_auto_age_check.button_pressed = bool(cfg.get("auto_age", true))
	_syncing_auto_ui = false
	var priority: Array = cfg.get("priority", ResearchAdvisor.DEFAULT_PRIORITY)
	for cid in ResearchAdvisor.CATEGORY_IDS:
		var rank := ResearchAdvisor.priority_rank(priority, String(cid))
		var rank_label: Label = _priority_rank_labels.get(cid)
		if rank_label != null:
			rank_label.text = str(rank + 1)
		var up: Button = _priority_up_buttons.get(cid)
		if up != null:
			up.disabled = rank <= 0
		var down: Button = _priority_down_buttons.get(cid)
		if down != null:
			down.disabled = rank >= priority.size() - 1
	var enabled := bool(cfg.get("enabled", false))
	_auto_foot.text = "科研官已启用，队列空闲时会自动开始研究。" if enabled else "科研官当前关闭，不会消耗任何资源。"
	_auto_btn.text = "⚙ 科研官：开" if enabled else "⚙ 科研官"

func _push_auto_config(cfg: Dictionary) -> void:
	if source_node == null or not source_node.has_method("ui_research_set_auto"):
		_auto_foot.text = "⚠ 当前模式不支持智能科研官"
		return
	var r: Dictionary = source_node.ui_research_set_auto(cfg)
	if r.has("ok") and not bool(r.get("ok", true)):
		_auto_foot.text = "⚠ " + String(r.get("error", "设置失败"))
		return
	_last_hash = ""
	_refresh_auto_ui()
	_auto_foot.text = "设置已保存，科研官会在队列空闲后按新优先级工作。"

func _on_auto_enabled_toggled(on: bool) -> void:
	if _syncing_auto_ui:
		return
	var cfg := _auto_config()
	cfg["enabled"] = on
	_push_auto_config(cfg)

func _on_auto_age_toggled(on: bool) -> void:
	if _syncing_auto_ui:
		return
	var cfg := _auto_config()
	cfg["auto_age"] = on
	_push_auto_config(cfg)

func _on_priority_move(cid: String, delta: int) -> void:
	var cfg := _auto_config()
	var priority: Array = cfg.get("priority", ResearchAdvisor.DEFAULT_PRIORITY).duplicate()
	var i := priority.find(cid)
	var j := i + delta
	if i < 0 or j < 0 or j >= priority.size():
		return
	var tmp = priority[i]
	priority[i] = priority[j]
	priority[j] = tmp
	cfg["priority"] = priority
	_push_auto_config(cfg)

func _select_category(cid: String) -> void:
	_selected_category = cid
	_last_hash = ""
	_rebuild()

func _state() -> Dictionary:
	if source_node != null and source_node.has_method("ui_research_state"):
		return source_node.ui_research_state()
	return {}

func _resources() -> Dictionary:
	if source_node != null and source_node.has_method("get_host_resources"):
		return source_node.get_host_resources()
	return {}

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var st := _state()
	if st.is_empty():
		return
	var cur: Dictionary = st.get("current", {})
	if cur.is_empty():
		_current_label.text = "研究队列空闲 — 选择一项科技开始研究"
		_progress.value = 0.0
		_cancel_btn.visible = false
	else:
		var total := maxf(float(cur.get("total", 1.0)), 0.1)
		var elapsed := float(cur.get("elapsed", 0.0))
		_progress.value = clampf(elapsed / total * 100.0, 0.0, 100.0)
		var left := maxf(total - elapsed, 0.0)
		_current_label.text = "研究中：%s  （剩余 %.0f 秒）" % [String(cur.get("name", "")), left]
		_cancel_btn.visible = String(cur.get("kind", "")) != "age"
	_update_age_panel(st)
	var auto_cfg := ResearchAdvisor.normalize_config(st.get("auto", {}))
	_auto_btn.text = "⚙ 科研官：开" if bool(auto_cfg.get("enabled", false)) else "⚙ 科研官"
	if _auto_panel != null and _auto_panel.visible:
		_refresh_auto_ui()
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = 0.35
		var h := _state_hash(st)
		if h != _last_hash:
			_last_hash = h
			_rebuild_grid(st)

func _state_hash(st: Dictionary) -> String:
	var cur: Dictionary = st.get("current", {})
	var res := _resources()
	return "%d|%d|%d|%s|%s|%d|%d|%d|%d|%d" % [
		int(st.get("age", 0)), int(st.get("bits", 0)), int(st.get("nation_bits", 0)),
		String(cur.get("id", "")), _selected_category,
		int(res.get("gold", 0)), int(res.get("wood", 0)), int(res.get("stone", 0)),
		int(res.get("food", 0)), int(res.get("oil", 0)),
	]

func _update_age_panel(st: Dictionary) -> void:
	var age := int(st.get("age", 0))
	var info := TechTreeData.get_age(age)
	_age_roman.text = String(info.get("roman", "I"))
	_age_label.text = String(info.get("name", ""))
	if age >= 3:
		_age_hint.text = "已抵达帝国时代。\n继续研究通用科技与本国特色科技，巩固终局优势。"
		_age_btn.text = "已达最高时代"
		_age_btn.disabled = true
		return
	var nxt := TechTreeData.next_age(age)
	var cur: Dictionary = st.get("current", {})
	var busy: bool = not cur.is_empty()
	var target := age + 1
	var lines: Array = []
	lines.append("下一时代：%s" % String(nxt.get("name", "")))
	lines.append("需要人口 ≥ %d" % int(nxt.get("pop", 0)))
	match target:
		1: lines.append("需要 2 座黑暗军事建筑（兵营/瞭望塔）")
		2: lines.append("需要 3 座封建建筑且至少 2 种\n（船坞/攻城车间/箭塔/集市/修道院）")
		3: lines.append("需要 4 座城堡建筑，其中至少 2 座城堡")
	lines.append("耗时 %d 秒（不可取消）" % int(nxt.get("time", 0)))
	lines.append(_cost_text(nxt.get("cost", {})))
	_age_hint.text = "\n".join(lines)
	_age_btn.text = "升级到 %s" % String(nxt.get("name", ""))
	_age_btn.disabled = busy or not _can_afford(nxt.get("cost", {}))
	if String(cur.get("kind", "")) == "age":
		_age_btn.text = "时代升级中…"
		_age_btn.disabled = true

func _rebuild() -> void:
	if _root_panel == null:
		return
	for cid in _tab_buttons:
		var b: Button = _tab_buttons[cid]
		if cid == _selected_category:
			b.modulate = Color(1.0, 0.92, 0.62)
		else:
			b.modulate = Color(1, 1, 1, 0.9)
	_rebuild_grid(_state())

func _tech_list() -> Array:
	if _selected_category == "N":
		var st := _state()
		var nation := int(st.get("nation", -1))
		if nation < 0 and source_node != null:
			var mn = source_node.get("my_nation")
			if mn != null:
				nation = int(mn)
		return TechTreeData.nation_techs(nation) if nation >= 0 else []
	var out: Array = []
	for t in TechTreeData.all_techs():
		if String(t.get("category", "")) == _selected_category:
			out.append(t)
	return out

func _rebuild_grid(st: Dictionary) -> void:
	if _grid == null:
		return
	for child in _grid.get_children():
		child.queue_free()
	var list := _tech_list()
	if list.is_empty():
		var empty := Label.new()
		empty.text = "本国特色科技将在选择国家后显示。"
		empty.add_theme_font_size_override("font_size", 16)
		empty.add_theme_color_override("font_color", UITheme.PARCHMENT)
		_grid.add_child(empty)
		return
	for t in list:
		var card := _make_card(t, st)
		if card != null:
			_grid.add_child(card)

func _make_card(t: Dictionary, st: Dictionary) -> Control:
	var tid := String(t.get("id", ""))
	var is_nation := String(t.get("kind", "")) == "nation"
	var age := int(st.get("age", 0))
	var bits := int(st.get("bits", 0))
	var nation := int(st.get("nation", -1))
	var nbits := int(st.get("nation_bits", 0))
	var current: Dictionary = st.get("current", {})
	var done := TechTreeData.has_nation_bit(nbits, nation, tid) if is_nation else TechTreeData.has_bit(bits, tid)
	var in_progress := String(current.get("id", "")) == tid
	var locked_reason := ""
	if not done and not in_progress:
		if int(t.get("age", 0)) > age:
			locked_reason = "需要%s" % TechTreeData.age_name(int(t.get("age", 0)))
		else:
			for p in t.get("prereq", []):
				var pid := String(p)
				var ok := TechTreeData.has_nation_bit(nbits, nation, pid) if pid.begins_with("N") else TechTreeData.has_bit(bits, pid)
				if not ok:
					locked_reason = "前置：%s" % pid
					break
		if locked_reason == "" and not current.is_empty():
			locked_reason = "研究队列忙碌"
		if locked_reason == "" and tid == "I2" and TechTreeData.has_bit(bits, "I6"):
			locked_reason = "与 I6 互斥"
		if locked_reason == "" and tid == "I6" and TechTreeData.has_bit(bits, "I2"):
			locked_reason = "与 I2 互斥"
		if locked_reason == "" and not _can_afford(t.get("cost", {})):
			locked_reason = "资源不足"

	var status := "✅ 已完成" if done else ("⏳ 研究中" if in_progress else ("🔒 " + locked_reason if locked_reason != "" else "可研究"))
	var cost_txt := _cost_text(t.get("cost", {}))
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_MIN
	card.tooltip_text = String(t.get("desc", ""))
	var accent := UITheme.GOLD
	if done:
		accent = Color(0.45, 0.9, 0.55)
	elif in_progress:
		accent = Color(0.4, 0.75, 1.0)
	elif locked_reason != "":
		accent = Color(0.45, 0.42, 0.38)
	card.add_theme_stylebox_override("panel", UITheme.card_style(accent))

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 3)
	card.add_child(vb)

	var name_label := Label.new()
	name_label.text = "%s  %s" % [String(t.get("id", "")), String(t.get("name", ""))]
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", UITheme.GOLD if not done else Color(0.7, 1.0, 0.75))
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(name_label)

	var effect_label := Label.new()
	effect_label.text = String(t.get("effect_text", ""))
	effect_label.add_theme_font_size_override("font_size", 13)
	effect_label.add_theme_color_override("font_color", UITheme.PARCHMENT)
	effect_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	effect_label.custom_minimum_size = Vector2(400, 34)
	effect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(effect_label)

	var foot := Label.new()
	foot.text = "%s · %d 秒  |  %s" % [cost_txt, int(t.get("time", 0)), status]
	foot.add_theme_font_size_override("font_size", 13)
	foot.add_theme_color_override("font_color", Color(0.72, 0.67, 0.56))
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(foot)

	var hit := Button.new()
	hit.flat = true
	hit.text = ""
	hit.focus_mode = Control.FOCUS_NONE
	hit.disabled = done or in_progress or locked_reason != ""
	hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for st_name in ["normal", "hover", "pressed", "disabled", "focus"]:
		hit.add_theme_stylebox_override(st_name, StyleBoxEmpty.new())
	card.add_child(hit)
	hit.pressed.connect(_on_tech_pressed.bind(tid))
	return card

func _can_afford(cost: Dictionary) -> bool:
	var res := _resources()
	for k in cost:
		if int(res.get(k, 0)) < int(cost[k]):
			return false
	return true

func _cost_text(cost: Dictionary) -> String:
	if cost.is_empty():
		return "免费"
	var names := {"food": "粮", "wood": "木", "gold": "金", "stone": "石", "oil": "油"}
	var parts: Array = []
	for k in ["food", "wood", "gold", "stone", "oil"]:
		if cost.has(k):
			parts.append("%s%d" % [names.get(k, k), int(cost[k])])
	return "成本 " + " ".join(parts)

func _on_tech_pressed(tid: String) -> void:
	if source_node == null or not source_node.has_method("ui_research_start"):
		return
	var r: Dictionary = source_node.ui_research_start(tid)
	if r.has("ok") and not bool(r.get("ok", true)):
		_foot_label.text = "⚠ " + String(r.get("error", "无法研究"))
	else:
		_foot_label.text = "已提交研究：" + tid
		_last_hash = ""

func _on_age_pressed() -> void:
	if source_node == null or not source_node.has_method("ui_research_start_age"):
		return
	var r: Dictionary = source_node.ui_research_start_age()
	if r.has("ok") and not bool(r.get("ok", true)):
		_foot_label.text = "⚠ " + String(r.get("error", "无法升级时代"))
	else:
		_foot_label.text = "时代升级已开始"
		_last_hash = ""

func _on_cancel_pressed() -> void:
	if source_node == null or not source_node.has_method("ui_research_cancel"):
		return
	var r: Dictionary = source_node.ui_research_cancel()
	if r.has("ok") and not bool(r.get("ok", true)):
		_foot_label.text = "⚠ " + String(r.get("error", "无法取消"))
	else:
		_foot_label.text = "已取消研究，资源按规则返还"
		_last_hash = ""

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and _auto_panel != null and _auto_panel.visible:
			_close_auto_panel()
			return
		if event.keycode == KEY_T:
			queue_free()
