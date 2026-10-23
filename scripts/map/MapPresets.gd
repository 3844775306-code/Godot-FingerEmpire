# 地图预设注册表
#
# 每张地图 = 地形配方(stages) + 资源画像(resources) + 规则修正(modifiers) + 外观(palette)。
# stages 为空时走 Ground._generate_classic()，与历史版本逐字节一致，作为默认图与回归基线。
# 取值一律返回深拷贝，调用方可随意修改（与 EntityDatabase.get_config() 的约定一致）。
extends RefCounted

const CLASSIC := "classic"

const PRESETS := {
	CLASSIC: {
		"id": CLASSIC,
		"name": "经典大陆",
		"battle": "",
		"desc": "随机大陆、山地与湖泊，标准对局地图。",
		"stages": [],
		"palette": {},
		"resources": {},
		"modifiers": {},
		"chips": ["标准地形"],
		"recommended": "全部模式",
	},
	"ridge": {
		"id": "ridge",
		"name": "白垩山脊",
		"battle": "海斯廷斯 1066",
		"desc": "东西山脊横贯全图，三处隘口决定攻守，全图金矿只分布在隘口。",
		"stages": [
			["noise_base", {"freq": 0.028, "octaves": 4}],
			["ridge", {"axis": "x", "center": 0.5, "width": 26.0, "strength": 0.62}],
			["passes", {"count": 3, "width": 4, "height": 1.6, "centers": [0.2, 0.5, 0.8]}],
		],
		"castle_layout": {"type": "mirror_z", "anchors": [[0.72, 0.82], [0.72, 0.18]], "flat_radius": 5},
		"palette": {},
		"resources": {"stone": 1.3, "wood_near": "any", "gold_at_passes": true},
		"modifiers": {"high_ground_vision": 0.25},
		"chips": ["三处隘口", "金矿只在隘口", "高地视野 +25%"],
		"recommended": "1v1",
	},
	"ford": {
		"id": "ford",
		"name": "大河渡口",
		"battle": "塞纳河桥头堡",
		"desc": "S 形大河纵切全图，两处浅滩是唯一陆路通道，河心水面藏油井。",
		"stages": [
			["noise_base", {"freq": 0.03, "octaves": 4}],
			["river", {"center": 0.5, "width": 7.0, "amp": 0.05, "freq": 0.06, "bulge_extra": 7.0, "bulge_len": 10.0}],
			["fords", {"positions": [0.3, 0.7], "width": 3}],
		],
		"castle_layout": {"type": "mirror_x", "anchors": [[0.2, 0.5], [0.8, 0.5]], "flat_radius": 5},
		"palette": {},
		"resources": {"oil": 1.5, "wood_near": "any"},
		"modifiers": {"ford_speed": 0.55},
		"chips": ["S 形大河", "两处浅滩", "河心油井"],
		"recommended": "1v1",
	},
	"forest": {
		"id": "forest",
		"name": "黑森林",
		"battle": "条顿堡 9 AD",
		"desc": "林海覆盖近四成地表，林中视野骤降；木材一株一株沿林线分布，伏击与侦察主导战场。",
		"stages": [
			["noise_base", {"freq": 0.03, "octaves": 4, "mountain_threshold": 0.42}],
			["forest", {"coverage": 0.50, "freq": 0.045, "clearing": 0.45}],
		],
		"castle_layout": {"type": "mirror_x", "anchors": [[0.22, 0.5], [0.78, 0.5]], "flat_radius": 5},
		"palette": {},
		"resources": {"wood": 1.5, "gold": 0.7, "wood_near": "forest", "stone_near": "any"},
		"modifiers": {},
		"chips": ["森林覆盖 35%", "林中视野 -45%", "木材沿林线单株分布"],
		"recommended": "1v1",
	},
}

static func has_preset(id: String) -> bool:
	return PRESETS.has(id)

static func get_preset(id: String) -> Dictionary:
	if PRESETS.has(id):
		return PRESETS[id].duplicate(true)
	return PRESETS[CLASSIC].duplicate(true)

static func all_ids() -> Array:
	return PRESETS.keys()

# UI 卡片只要这几项，避免把生成参数漏到界面层
static func get_info(id: String) -> Dictionary:
	var p := get_preset(id)
	return {
		"id": p.get("id", CLASSIC),
		"name": p.get("name", "经典大陆"),
		"battle": p.get("battle", ""),
		"desc": p.get("desc", ""),
		"chips": p.get("chips", []).duplicate(),
		"recommended": p.get("recommended", ""),
	}
