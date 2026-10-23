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
	"marsh": {
		"id": "marsh",
		"name": "沼泽泥潭",
		"battle": "阿金库尔 1415",
		"desc": "泥沼覆盖三成平原，涉沼行军速度骤减；金矿多而林木稀，绕行长线与补给拉扯决定胜负。",
		"stages": [
			["noise_base", {"freq": 0.03, "octaves": 4, "mountain_threshold": 0.36}],
			["marsh", {"coverage": 0.34, "freq": 0.05}],
		],
		"castle_layout": {"type": "mirror_x", "anchors": [[0.18, 0.5], [0.82, 0.5]], "flat_radius": 6},
		"palette": {
			"plain_low": [0.11, 0.24, 0.11],
			"plain_high": [0.32, 0.40, 0.19],
			"water_deep": [0.09, 0.24, 0.26],
			"water_shallow": [0.22, 0.44, 0.42],
		},
		"resources": {"gold": 1.25, "wood": 0.8, "stone": 0.8},
		"modifiers": {"marsh_speed": 0.6},
		"chips": ["泥沼遍布平原", "泥地行军 -40%", "金矿较多"],
		"recommended": "1v1 / 2v2 / 3v3",
	},
	"strait": {
		"id": "strait",
		"name": "群岛海峡",
		"battle": "萨拉米斯 480 BC",
		"desc": "宽阔海峡把大陆切成两半，两处浅滩是陆军唯一通路；海面上十几座孤立岛屿只作地标，近岸油井提供额外资源。",
		"stages": [
			["noise_base", {"freq": 0.03, "octaves": 4}],
			["sea", {"center": 0.5, "width_frac": 0.16, "amp": 0.05, "freq": 0.035}],
			["islets", {"count": 14, "big": 2, "band": 0.5, "radius_min": 2, "radius_max": 4, "big_radius": 6, "avoid": [0.28, 0.72]}],
			["fords", {"positions": [0.28, 0.72], "width": 4}],
		],
		"castle_layout": {"type": "mirror_x", "anchors": [[0.16, 0.5], [0.84, 0.5]], "flat_radius": 6},
		"palette": {
			"water_deep": [0.07, 0.26, 0.46],
			"water_shallow": [0.22, 0.56, 0.70],
		},
		"resources": {"oil": 1.8, "wood": 0.9, "stone": 0.9},
		"modifiers": {"ford_speed": 0.5},
		"reachable_only": true,
		"oil_near_shore": true,
		"chips": ["海峡横断", "孤立岛屿", "两处渡口", "海上油井"],
		"recommended": "1v1 / 2v2 / 3v3",
	},
	"desert": {
		"id": "desert",
		"name": "沙漠绿洲",
		"battle": "哈丁角 1187",
		"desc": "开阔沙海几乎无遮蔽，视野大幅提升；除每座城堡一处农田外食物主要靠狩猎兽群，绿洲与中部金矿让机动抢点成为胜负手。",
		"stages": [
			["noise_base", {"freq": 0.045, "octaves": 3, "mountain_threshold": 0.42, "water_threshold": -0.95}],
			["oasis", {"spots": [[0.28, 0.32], [0.5, 0.62], [0.72, 0.38], [0.42, 0.8]], "radius_frac": 0.032}],
		],
		"castle_layout": {"type": "mirror_x", "anchors": [[0.18, 0.5], [0.82, 0.5]], "flat_radius": 6},
		"palette": {
			"plain_low": [0.62, 0.52, 0.30],
			"plain_high": [0.84, 0.74, 0.48],
			"mountain_low": [0.55, 0.45, 0.28],
			"mountain_high": [0.80, 0.71, 0.52],
			"water_deep": [0.06, 0.30, 0.42],
			"water_shallow": [0.20, 0.55, 0.60],
		},
		"resources": {"gold": 1.3, "wood": 0.55, "stone": 0.9, "food": 0.0, "oil": 1.0, "animals": 2.6},
		"modifiers": {"vision": 1.2},
		"reachable_only": true,
		"oil_near_shore": true,
		"chips": ["开阔沙海", "视野 +20%", "农田稀少靠狩猎"],
		"recommended": "1v1 / 2v2 / 3v3",
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
