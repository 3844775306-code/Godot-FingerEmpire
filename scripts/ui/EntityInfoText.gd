# scripts/ui/EntityInfoText.gd
# 信息面板「详细」模式的文本拼装：尽量对齐单位图鉴的分类、属性、来源与说明，
# 但输出为 BBCode 富文本，交给面板里的 ScrollContainer 滚动。
class_name EntityInfoText
extends RefCounted

const UV = preload("res://scripts/ui/UnitView.gd")

const TYPE_NAMES := { 0: "资源", 1: "建筑", 2: "单位" }
const NATION_NAMES := ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭", "蒙古", "波斯", "西班牙"]
const CLASS_CN := {
	"military": "军事单位",
	"siege": "攻城单位",
	"navy": "海军单位",
	"economy": "经济单位",
	"merchant": "贸易商人",
	"official": "朝廷官员",
	"religion": "宗教单位",
	"animal": "野生动物",
	"building": "建筑",
	"resource": "野外资源",
}
const TARGET_TEXT := {
	0: "仅能攻击建筑 / 资源",
	1: "优先攻击建筑",
	2: "优先攻击士兵",
	3: "优先攻击远程 / 攻城器",
}

# current 可传当前单位的实时状态（health / attack / attack_range / speed / level /
# task），用于让详细页显示“现在”的数值；不传则只显示配置表的基准值。
static func detailed(entity_id: int, current: Dictionary = {}) -> String:
	var cfg: Dictionary = EntityDatabase.get_config(entity_id)
	if cfg.is_empty():
		return _line("暂无该实体的配置数据。", UITheme.VERMILION)
	var type_id: int = int(cfg.get("type", 2))
	var lines: Array[String] = []

	lines.append(_header("📖 实体档案"))
	lines.append(_pair("名称", str(cfg.get("name", "未知"))))
	var owner_nation := int(current.get("nation", -1))
	if owner_nation >= 0:
		lines.append(_pair("所属国家", _nation_name(owner_nation)))
	lines.append(_pair("编号", "ID %d · %s" % [entity_id, TYPE_NAMES.get(type_id, "实体")]))
	lines.append(_pair("分类", _class_label(entity_id, type_id)))
	var role := _role_hint(cfg)
	if role != "":
		lines.append(_pair("定位", role))
	var nation := str(UV.NATION_TAGS.get(entity_id, ""))
	if nation != "":
		lines.append(_pair("国家特色", nation))
	var lv := int(current.get("level", 0))
	if lv > 0:
		lines.append(_pair("当前等级", "Lv.%d" % lv))
	var task := str(current.get("task", ""))
	if task != "":
		lines.append(_pair("当前任务", task))

	lines.append("")
	lines.append(_line(str(UV.DESC.get(entity_id, "没有更多说明。")), UITheme.PARCHMENT))
	lines.append(_rule())

	lines.append(_header("📊 属性"))
	_add_stats(lines, cfg, current, type_id)
	_add_cost_and_source(lines, cfg, type_id, entity_id)

	lines.append(_rule())
	lines.append(_header("📜 机制与说明"))
	_add_mechanics(lines, cfg, type_id)
	return "\n".join(lines)

static func _add_stats(lines: Array[String], cfg: Dictionary, current: Dictionary, type_id: int) -> void:
	if type_id == 0:
		var rt := str(cfg.get("resource_type", ""))
		lines.append(_pair("产出资源", str(UITheme.RESOURCE_NAMES.get(rt, rt))))
		if cfg.has("gather_amount"):
			lines.append(_pair("单次采集量", _num(cfg["gather_amount"])))
		if cfg.has("regeneration_rate"):
			lines.append(_pair("恢复速率", "每秒 +%s" % _num(cfg["regeneration_rate"])))
		return

	var max_hp := float(current.get("max_health", cfg.get("max_health", 0)))
	var hp := float(current.get("health", max_hp))
	if max_hp > 0.0:
		var hp_txt := "%s / %s" % [_num(hp), _num(max_hp)]
		if absf(hp - max_hp) > 0.01:
			hp_txt += "  (%d%%)" % int(round(100.0 * hp / max(max_hp, 1.0)))
		lines.append(_pair("生命", hp_txt))
	var atk := float(current.get("attack", cfg.get("attack", 0)))
	var atk_speed := float(cfg.get("attack_speed", 0.0))
	var dps := 0.0
	if atk > 0.0 and atk_speed > 0.0:
		dps = atk / atk_speed
	lines.append(_pair("攻击", _num(atk) if atk > 0.0 else "—"))
	if atk_speed > 0.0:
		lines.append(_pair("攻击间隔", "%s 秒/次" % _num(atk_speed)))
	if dps > 0.0:
		lines.append(_pair("秒伤 DPS", "%.1f" % dps))
	var atk_range := float(current.get("attack_range", cfg.get("attack_range", 0.0)))
	if atk_range > 0.0:
		lines.append(_pair("攻击距离", _num(atk_range)))
	var vision := float(cfg.get("vision_range", 0.0))
	if vision > 0.0:
		lines.append(_pair("视野", _num(vision)))
	var armor_parts: Array[String] = []
	if int(cfg.get("melee_armor", 0)) > 0:
		armor_parts.append("近战 %s" % _num(cfg["melee_armor"]))
	if int(cfg.get("shield_armor", 0)) > 0:
		armor_parts.append("远程 %s" % _num(cfg["shield_armor"]))
	if not armor_parts.is_empty():
		lines.append(_pair("护甲", "，".join(armor_parts)))
	var speed := float(current.get("speed", cfg.get("speed", 0.0)))
	if speed > 0.0:
		lines.append(_pair("移动速度", _num(speed)))
	if cfg.has("damage_radius") and float(cfg["damage_radius"]) > 0.0:
		lines.append(_pair("溅射半径", _num(cfg["damage_radius"])))
	if cfg.has("body_radius"):
		lines.append(_pair("体积半径", _num(cfg["body_radius"])))
	if cfg.has("regeneration_rate") and type_id != 0:
		lines.append(_pair("自愈", "每秒 +%s" % _num(cfg["regeneration_rate"])))

static func _add_cost_and_source(lines: Array[String], cfg: Dictionary, type_id: int, entity_id: int) -> void:
	var cost := _cost_string(cfg)
	if cost != "":
		lines.append("")
		lines.append(_header("🪙 " + ("建造价格" if type_id == 1 else "生产价格")))
		lines.append(_line(cost, UITheme.GOLD))

	if type_id == 1:
		var prods: Array = cfg.get("produces", [])
		if not prods.is_empty():
			lines.append("")
			lines.append(_header("📋 可训练 / 可产出"))
			for p in prods:
				var pid := int(p.get("unit_id", -1))
				var pc: Dictionary = EntityDatabase.get_config(pid)
				lines.append(_pair("· %s" % str(pc.get("name", "单位 %d" % pid)),
					"冷却 %s 秒 · 队列 %d" % [_num(p.get("cooldown", 0)), int(p.get("queue_limit", 1))]))
		var ups: Array = cfg.get("upgrades", [])
		if not ups.is_empty():
			lines.append("")
			lines.append(_header("📈 升级路线"))
			for u in ups:
				var extra: Array[String] = []
				if u.has("health_bonus"):
					extra.append("生命 +%s" % _num(u["health_bonus"]))
				if u.has("attack_bonus"):
					extra.append("攻击 +%s" % _num(u["attack_bonus"]))
				if u.has("melee_armor_bonus"):
					extra.append("近战护甲 +%s" % _num(u["melee_armor_bonus"]))
				if u.has("shield_armor_bonus"):
					extra.append("远程护甲 +%s" % _num(u["shield_armor_bonus"]))
				var unlock := _upgrade_unlock_names(u)
				if unlock != "":
					extra.append("解锁 " + unlock)
				lines.append(_pair("Lv.%s" % str(u.get("level", "?")),
					_cost_string(u) + ("；" + "，".join(extra) if not extra.is_empty() else "")))
	else:
		var source := _training_sources(entity_id)
		if source != "":
			lines.append("")
			lines.append(_header("🏫 训练 / 解锁来源"))
			lines.append(_line(source, UITheme.PARCHMENT))

static func _add_mechanics(lines: Array[String], cfg: Dictionary, type_id: int) -> void:
	if type_id == 0:
		return
	if type_id == 1:
		var passives: Array[String] = []
		if cfg.has("population_bonus") and int(cfg["population_bonus"]) > 0:
			passives.append("人口上限 +%s" % _num(cfg["population_bonus"]))
		if cfg.has("storage_bonus") and int(cfg["storage_bonus"]) > 0:
			passives.append("仓储上限 +%s" % _num(cfg["storage_bonus"]))
		if bool(cfg.get("wall_only", false)):
			passives.append("仅可建造于城墙旁")
		if bool(cfg.get("can_repair", false)):
			passives.append("可修理")
		if passives.is_empty():
			lines.append(_line("该建筑没有额外的被动效果。", UITheme.STONE))
		else:
			lines.append(_pair("被动 / 特性", "，".join(passives)))
		return

	if cfg.get("gatherable_resources", []).size() > 0:
		var gnames: Array[String] = []
		for r in cfg["gatherable_resources"]:
			gnames.append(str(UITheme.RESOURCE_ICONS.get(r, "·")) + " " + str(UITheme.RESOURCE_NAMES.get(r, r)))
		lines.append(_pair("可采集", "，".join(gnames)))
	if cfg.has("max_cargo"):
		lines.append(_pair("载货量", _num(cfg["max_cargo"])))
	if cfg.get("merchant_type", "") != "":
		var m := str(cfg["merchant_type"])
		lines.append(_pair("贸易品类", "%s %s" % [UITheme.RESOURCE_ICONS.get(m, ""), UITheme.RESOURCE_NAMES.get(m, m)]))
	if cfg.get("official_type", "") != "":
		var o := str(cfg["official_type"])
		lines.append(_pair("官职", "%s（%s）" % [UV.OFFICIAL_NAME.get(o, o), UV.OFFICIAL_ROLE.get(o, "")]))
		if cfg.has("salary"):
			lines.append(_pair("俸禄", "每周期 %s 黄金" % _num(cfg["salary"])))
		var aura := _official_aura(cfg)
		if aura != "":
			lines.append(_pair("光环", aura))
	if cfg.get("special_type", "") != "":
		lines.append(_pair("特殊定位", _special_text(str(cfg["special_type"]))))
	if cfg.get("multiple_process", []).size() > 0:
		lines.append(_pair("特殊机制", "多重攻击（单次出手复数弩箭）"))
	if bool(cfg.get("piercing", false)):
		lines.append(_pair("特殊机制", "对兵海有额外穿透效果"))
	if bool(cfg.get("ignore_armor", false)):
		lines.append(_pair("特殊机制", "攻击无视目标护甲"))
	if bool(cfg.get("ignore_building_armor", false)):
		lines.append(_pair("特殊机制", "攻击无视建筑护甲"))
	if bool(cfg.get("water_capable", false)):
		lines.append(_pair("地形", "可在水面行动"))
	var tt := int(cfg.get("target_type", -1))
	if TARGET_TEXT.has(tt):
		lines.append(_pair("索敌倾向", TARGET_TEXT[tt]))
	var tags := _combat_tags(cfg)
	if tags != "":
		lines.append(_pair("战斗标签", tags))
	if cfg.get("animal_type", "") != "":
		lines.append(_pair("狩猎产出", "食物 +%s" % _num(cfg.get("food_reward", 0))))

static func _training_sources(unit_id: int) -> String:
	var parts: Array[String] = []
	var seen: Dictionary = {}
	for bid in EntityDatabase.configs.keys():
		var bc: Dictionary = EntityDatabase.configs[bid]
		if int(bc.get("type", -1)) != 1:
			continue
		var bname := str(bc.get("name", "建筑"))
		for p in bc.get("produces", []):
			if int(p.get("unit_id", -1)) != unit_id:
				continue
			var key := "produce:%s" % bname
			if seen.has(key):
				continue
			seen[key] = true
			parts.append("%s（冷却 %s 秒，队列 %d）" % [
				bname, _num(p.get("cooldown", 0)), int(p.get("queue_limit", 1))])
		for u in bc.get("upgrades", []):
			if not _upgrade_unlocks(u, unit_id):
				continue
			var ukey := "unlock:%s:%s" % [bname, str(u.get("level", "?"))]
			if seen.has(ukey):
				continue
			seen[ukey] = true
			parts.append("%s（升级 Lv.%s 解锁）" % [bname, str(u.get("level", "?"))])
	return "，".join(parts)

static func _upgrade_unlocks(u: Dictionary, unit_id: int) -> bool:
	if u.has("unlocks_units") and u["unlocks_units"] is Array:
		for uid in u["unlocks_units"]:
			if int(uid) == unit_id:
				return true
	if u.has("unlocks_unit") and int(u["unlocks_unit"]) == unit_id:
		return true
	return false

static func _upgrade_unlock_names(u: Dictionary) -> String:
	var names: Array[String] = []
	if u.has("unlocks_units") and u["unlocks_units"] is Array:
		for uid in u["unlocks_units"]:
			names.append(_unit_name(int(uid)))
	elif u.has("unlocks_unit"):
		names.append(_unit_name(int(u["unlocks_unit"])))
	return "，".join(names)

static func _unit_name(unit_id: int) -> String:
	var cfg: Dictionary = EntityDatabase.get_config(unit_id)
	return str(cfg.get("name", "单位 %d" % unit_id))

static func _class_label(entity_id: int, type_id: int) -> String:
	for key in UV.CLASS_GROUPS.keys():
		if entity_id in (UV.CLASS_GROUPS[key] as Array):
			return CLASS_CN.get(key, TYPE_NAMES.get(type_id, "实体"))
	if type_id == 0:
		return CLASS_CN["resource"]
	if type_id == 1:
		return CLASS_CN["building"]
	return TYPE_NAMES.get(type_id, "实体")

static func _role_hint(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if int(cfg.get("type", 2)) == 2:
		if bool(cfg.get("water_capable", false)):
			parts.append("可在水面行动")
		if bool(cfg.get("can_move", false)):
			parts.append("移动单位")
		elif cfg.has("can_move"):
			parts.append("驻守单位")
	if cfg.get("merchant_type", "") != "":
		var m := str(cfg["merchant_type"])
		if UITheme.RESOURCE_NAMES.has(m):
			parts.append("主营%s贸易" % str(UITheme.RESOURCE_NAMES[m]))
	if cfg.get("official_type", "") != "":
		parts.append(str(UV.OFFICIAL_ROLE.get(str(cfg["official_type"]), "")))
	if cfg.get("special_type", "") == "monk":
		parts.append("修士")
	if cfg.get("animal_type", "") != "":
		parts.append("可猎杀")
	return "，".join(parts)

static func _combat_tags(cfg: Dictionary) -> String:
	var tags: Array[String] = []
	if bool(cfg.get("ignore_armor", false)):
		tags.append("无视护甲")
	if bool(cfg.get("ignore_building_armor", false)):
		tags.append("无视建筑护甲")
	if float(cfg.get("damage_radius", 0.0)) > 0.0:
		tags.append("溅射伤害")
	if float(cfg.get("attack_range", 0.0)) >= 3.0:
		tags.append("远程")
	elif float(cfg.get("attack", 0)) > 0.0:
		tags.append("近战")
	return "，".join(tags)

static func _official_aura(cfg: Dictionary) -> String:
	var parts: Array[String] = []
	if cfg.has("aura_radius") and float(cfg["aura_radius"]) > 0.0:
		parts.append("影响范围 %s" % _num(cfg["aura_radius"]))
	if cfg.has("aura_attack_speed") and float(cfg["aura_attack_speed"]) > 0.0:
		parts.append("友军攻速 +%d%%" % int(float(cfg["aura_attack_speed"]) * 100.0))
	if cfg.has("speed_bonus") and float(cfg["speed_bonus"]) > 0.0:
		parts.append("友军移速 +%d%%" % int(float(cfg["speed_bonus"]) * 100.0))
	if cfg.has("melee_armor_bonus") and float(cfg["melee_armor_bonus"]) > 0.0:
		parts.append("友军近战护甲 +%s" % _num(cfg["melee_armor_bonus"]))
	if cfg.has("shield_armor_bonus") and float(cfg["shield_armor_bonus"]) > 0.0:
		parts.append("友军远程护甲 +%s" % _num(cfg["shield_armor_bonus"]))
	if cfg.has("efficiency_multiplier") and float(cfg["efficiency_multiplier"]) > 1.0:
		parts.append("周边采集效率 ×%s" % _num(cfg["efficiency_multiplier"]))
	return "，".join(parts)

static func _special_text(kind: String) -> String:
	match kind:
		"monk": return "修道院培养的修士，治疗友军"
		"elder": return "无视目标护甲的高阶修士"
		"grandmaster": return "武学宗师，降攻并有机会招降目标"
		_: return kind

static func _cost_string(cfg: Dictionary) -> String:
	var cost = cfg.get("cost")
	if not (cost is Dictionary) or cost.is_empty():
		return ""
	var parts: Array[String] = []
	var order := ["gold", "wood", "stone", "food", "oil"]
	for r in order:
		if cost.has(r) and int(cost[r]) > 0:
			parts.append("%s %s" % [str(UITheme.RESOURCE_ICONS.get(r, "·")), _num(cost[r])])
	for key in cost.keys():
		if order.has(key) or int(cost[key]) <= 0:
			continue
		parts.append("%s %s" % [str(UITheme.RESOURCE_ICONS.get(key, "·")), _num(cost[key])])
	return "　".join(parts)

static func _nation_name(nation: int) -> String:
	if nation >= 0 and nation < NATION_NAMES.size():
		return String(NATION_NAMES[nation])
	return "未知"

static func _num(v) -> String:
	var f := float(v)
	var s := "%.2f" % f
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s

static func _header(text: String) -> String:
	return "[color=%s][b]%s[/b][/color]" % [UITheme.hex_str(UITheme.GOLD), text]

static func _pair(label: String, value: String) -> String:
	return "[color=%s]%s[/color]：[color=%s]%s[/color]" % [
		UITheme.hex_str(UITheme.PARCHMENT), label,
		UITheme.hex_str(UITheme.PARCHMENT.lightened(0.18)), value]

static func _line(text: String, color: Color) -> String:
	return "[color=%s]%s[/color]" % [UITheme.hex_str(color), text]

static func _rule() -> String:
	return "[color=%s]────────────────────────[/color]" % UITheme.hex_str(Color(UITheme.GOLD, 0.4))
