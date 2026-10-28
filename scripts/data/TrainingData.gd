extends RefCounted

# 新兵训练营关卡数据。
#
# 与 CampaignData 保持相同的关卡字典结构，CampaignDirector 可以直接复用；
# 额外字段：
#   concepts       本关两个知识点（教学关必须有且只有两个）
#   unlock_units   本关新解锁兵种
#   unlock_buildings 本关新解锁建筑
#   nation_select  第 24 关：开局前选择国家
#   multi_mode     第 25/26 关：2v2 / 1v2 多 AI 关卡
#
# 关卡白名单是累计的：第 N 关可用第 1~N 关所有 unlock，挑战关 unlock 为空。

const CHAPTERS := [
	{"id": 1, "name": "入伍", "desc": "农民、主城与第一支陆军"},
	{"id": 2, "name": "耳目与壁垒", "desc": "侦察、视野与防御"},
	{"id": 3, "name": "铁骑与攻城", "desc": "机动、经济与攻城器"},
	{"id": 4, "name": "远程与渡海", "desc": "远程火力与海军"},
	{"id": 5, "name": "进阶", "desc": "重装、修道院、集市与书院"},
	{"id": 6, "name": "列国演武", "desc": "国家特色、2v2 与 1v2"},
]

# 国家 -> 特色兵种 id
const NATION_UNITS := {
	0: 30, 1: 31, 2: 32, 3: 33, 4: 34,
	5: 65, 6: 66, 7: 67, 8: 68, 9: 69,
}

const NATION_NAMES := ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭", "蒙古", "波斯", "西班牙"]

const TYPE_LABELS := {
	"教学": "教学",
	"进攻挑战": "进攻",
	"防守挑战": "防守",
	"任务挑战": "任务",
	"综合挑战": "综合",
	"国家试炼": "国家试炼",
	"团队挑战": "2v2",
	"高难挑战": "1v2",
}

static func _p(units: Array, resources: Dictionary, buildings: Array = [], castle_level: int = 1,
		navy: Array = [], pop_cap: int = 60, castle: bool = true, nation: int = 0) -> Dictionary:
	return {
		"nation": nation,
		"castle": castle,
		"castle_level": castle_level,
		"buildings": buildings,
		"units": units,
		"navy": navy,
		"resources": resources,
		"pop_cap": pop_cap,
	}

static func _e(units: Array, resources: Dictionary, waves: Array = [], buildings: Array = [],
		castle: bool = false, ai: bool = false, castle_level: int = 1, nation: int = 1,
		pop_cap: int = 60) -> Dictionary:
	return {
		"nation": nation,
		"castle": castle,
		"castle_level": castle_level,
		"buildings": buildings,
		"units": units,
		"waves": waves,
		"resources": resources,
		"pop_cap": pop_cap,
		"ai": ai,
	}

static func _level(spec: Dictionary) -> Dictionary:
	var d := {
		"id": "",
		"index": 1,
		"chapter": 1,
		"name": "",
		"type": "教学",
		"map_id": "classic",
		"map_seed": 1,
		"time_limit": 600.0,
		"stars": {"two": 600.0, "three": 420.0},
		"player": _p([], {}),
		"enemy": _e([], {}),
		"objectives": [],
		"fail": ["castle_lost", "timeout"],
		"unlock_units": [],
		"unlock_buildings": [],
		"concepts": [],
		"brief": "",
		"nation_select": false,
		"multi_mode": "",
	}
	d.merge(spec, true)
	d["type_label"] = String(TYPE_LABELS.get(String(d.get("type", "教学")), String(d.get("type", "教学"))))
	return d

static func levels() -> Array:
	var out: Array = []
	# ── 基础篇 ────────────────────────────────────────────────
	out.append(_level({
		"id": "t01", "index": 1, "chapter": 1, "name": "新兵入营",
		"type": "教学", "map_id": "classic", "map_seed": 101,
		"time_limit": 420.0, "stars": {"two": 300.0, "three": 180.0},
		"concepts": [
			{"name": "农民", "kind": "unit", "id": 10, "icon": "🌾", "desc": "采集木/粮/金/石，建造和修理建筑。没有农民就没有经济。"},
			{"name": "主城", "kind": "building", "id": 20, "icon": "🏰", "desc": "训练农民与侦察兵、升级时代；主城被拆即失败，优先保护。"},
		],
		"unlock_units": [10],
		"player": _p(
			[{"id": 10, "count": 5}],
			{"gold": 500, "wood": 600, "stone": 300, "food": 600, "oil": 0},
			[], 1, [], 40),
		"enemy": _e([], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}),
		"objectives": [
			{"type": "gather", "amount": 300.0, "label": "累计采集 300 资源"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "先让农民去采木和采粮；主城可以训练更多农民。资源是后面所有训练的基础。",
	}))

	out.append(_level({
		"id": "t02", "index": 2, "chapter": 1, "name": "立营练兵",
		"type": "教学", "map_id": "classic", "map_seed": 102,
		"time_limit": 480.0, "stars": {"two": 360.0, "three": 240.0},
		"concepts": [
			{"name": "兵营", "kind": "building", "id": 21, "icon": "⚔️", "desc": "训练步兵、弓箭手、骑兵和长枪兵；升级兵营解锁更高级兵种。"},
			{"name": "步兵", "kind": "unit", "id": 11, "icon": "🛡️", "desc": "便宜、耐打的前排。适合吸收伤害、保护后排，不要单独冲进人堆。"},
		],
		"unlock_units": [11],
		"unlock_buildings": [21],
		"player": _p(
			[{"id": 10, "count": 5}],
			{"gold": 600, "wood": 700, "stone": 400, "food": 700, "oil": 0},
			[], 1, [], 40),
		"enemy": _e(
			[{"id": 11, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [], false, false, 1, 1, 30),
		"objectives": [
			{"type": "kill_units", "unit_ids": [11], "count": 3, "label": "击杀 3 名敌方步兵"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "在城堡旁边建兵营，训练 6 名步兵，合兵后一起推进。步兵是前排，不要一个一个送。",
	}))

	out.append(_level({
		"id": "t03", "index": 3, "chapter": 1, "name": "弓手与炊烟",
		"type": "教学", "map_id": "classic", "map_seed": 103,
		"time_limit": 480.0, "stars": {"two": 360.0, "three": 240.0},
		"concepts": [
			{"name": "民居", "kind": "building", "id": 28, "icon": "🏠", "desc": "每座 +5 人口上限。人口满了就无法继续生产，经济关要提前补。"},
			{"name": "弓箭手", "kind": "unit", "id": 12, "icon": "🏹", "desc": "5 格射程、血少。站在步兵后面输出，怕骑兵贴脸和范围伤害。"},
		],
		"unlock_units": [12],
		"unlock_buildings": [28],
		"player": _p(
			[{"id": 10, "count": 5}, {"id": 11, "count": 4}],
			{"gold": 700, "wood": 800, "stone": 400, "food": 800, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2, [], 45),
		"enemy": _e(
			[{"id": 11, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [], false, false, 1, 1, 30),
		"objectives": [
			{"type": "kill_units", "unit_ids": [11], "count": 3, "label": "用弓箭手击杀 3 名敌方步兵"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "先补 2 座民居解除人口上限，再训练弓箭手。步兵顶在前面，弓箭手在后方输出。",
	}))

	out.append(_level({
		"id": "t04", "index": 4, "chapter": 1, "name": "拔除前哨",
		"type": "进攻挑战", "map_id": "ridge", "map_seed": 104,
		"time_limit": 480.0, "stars": {"two": 360.0, "three": 240.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 5}, {"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 600, "wood": 700, "stone": 400, "food": 700, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2, [], 45),
		"enemy": _e(
			[{"id": 11, "count": 4}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [{"id": 21, "level": 1, "offset": [0, 0]}, {"id": 25, "level": 1, "offset": [8, 5]}],
			false, false, 2, 1, 40),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [21], "count": 1, "label": "摧毁敌方前哨兵营"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "只用已经学过的农民、步兵、弓箭手。步兵先上，弓箭手在后，拆掉兵营就赢。",
	}))

	out.append(_level({
		"id": "t05", "index": 5, "chapter": 2, "name": "耳聪目明",
		"type": "教学", "map_id": "forest", "map_seed": 105,
		"time_limit": 480.0, "stars": {"two": 360.0, "three": 240.0},
		"concepts": [
			{"name": "侦察兵", "kind": "unit", "id": 19, "icon": "🐎", "desc": "速度 3.5、视野远，不擅长正面战斗；用来探路、开图、找敌方部队。"},
			{"name": "瞭望塔", "kind": "building", "id": 41, "icon": "🗼", "desc": "扩大固定区域视野。把它放在路口或资源点，提前发现来袭方向。"},
		],
		"unlock_units": [19],
		"unlock_buildings": [41],
		"player": _p(
			[{"id": 10, "count": 5}, {"id": 11, "count": 4}],
			{"gold": 600, "wood": 800, "stone": 400, "food": 600, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2, [], 45),
		"enemy": _e([], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0}),
		"objectives": [
			{"type": "hold_zone", "hold": 20.0, "zone": {"radius": 8.0, "offset": [0, 0]},
				"label": "派兵占领中央观察点 20 秒"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "先用侦察兵探开中央区域，再建瞭望塔守住视野。黑森林里视野比兵力更重要。",
	}))

	out.append(_level({
		"id": "t06", "index": 6, "chapter": 2, "name": "筑墙守土",
		"type": "教学", "map_id": "ridge", "map_seed": 106,
		"time_limit": 420.0, "stars": {"two": 300.0, "three": 180.0},
		"concepts": [
			{"name": "城墙", "kind": "building", "id": 27, "icon": "🧱", "desc": "高护甲，阻挡陆军。不要全封死，留一个缺口让敌人走进箭塔火力。"},
			{"name": "箭塔", "kind": "building", "id": 25, "icon": "🏹", "desc": "自动攻击范围内敌人，血厚。放在墙后或资源点旁，交叉火力最强。"},
		],
		"unlock_buildings": [27, 25],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 700, "wood": 900, "stone": 900, "food": 800, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2, [], 55),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 15.0, "label": "试探进攻", "units": [{"id": 11, "count": 3}]},
				{"time": 50.0, "label": "第二波", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 2}]},
				{"time": 85.0, "label": "第三波", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 3}]},
				{"time": 110.0, "label": "最后一波", "units": [{"id": 11, "count": 5}, {"id": 12, "count": 3}]},
			], [], false, false, 1, 1, 40),
		"objectives": [
			{"type": "survive", "duration": 120.0, "label": "守住 2 分钟"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "用城墙围出一个带缺口的防线，在缺口后方建 2 座箭塔。不要把墙完全封死，否则敌人会绕路。",
	}))

	out.append(_level({
		"id": "t07", "index": 7, "chapter": 2, "name": "背城借一",
		"type": "防守挑战", "map_id": "ridge", "map_seed": 107,
		"time_limit": 420.0, "stars": {"two": 300.0, "three": 180.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 8}, {"id": 12, "count": 6}],
			{"gold": 800, "wood": 900, "stone": 900, "food": 900, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}, {"id": 25, "level": 1, "offset": [9, 4]}],
			2, [], 60),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 20.0, "label": "第一波", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 2}]},
				{"time": 80.0, "label": "第二波", "units": [{"id": 11, "count": 5}, {"id": 12, "count": 3}]},
				{"time": 140.0, "label": "第三波", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 4}]},
				{"time": 205.0, "label": "第四波", "units": [{"id": 11, "count": 7}, {"id": 12, "count": 4}]},
				{"time": 270.0, "label": "第五波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 5}]},
			], [], false, false, 2, 1, 50),
		"objectives": [
			{"type": "survive", "duration": 300.0, "label": "守住 5 分钟、击退 5 波进攻"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "这一关不教新东西。用城墙、箭塔、步兵和弓箭手守住主城，注意敌人的远程火力。",
	}))

	out.append(_level({
		"id": "t08", "index": 8, "chapter": 3, "name": "铁骑截粮",
		"type": "教学", "map_id": "ridge", "map_seed": 108,
		"time_limit": 540.0, "stars": {"two": 420.0, "three": 300.0},
		"concepts": [
			{"name": "骑兵", "kind": "unit", "id": 15, "icon": "🐎", "desc": "速度 2.5、血量高，适合绕后、截杀农民和追击；正面撞枪阵会亏。"},
			{"name": "仓库", "kind": "building", "id": 22, "icon": "📦", "desc": "提高资源储存上限，并让县吏进驻获得采集加成。后期经济必备。"},
		],
		"unlock_units": [15],
		"unlock_buildings": [22],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 5}, {"id": 12, "count": 3}],
			{"gold": 900, "wood": 900, "stone": 500, "food": 900, "oil": 0},
			[{"id": 21, "level": 3, "offset": [-7, 5]}], 3, [], 55),
		"enemy": _e(
			[{"id": 10, "count": 5}, {"id": 11, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [], false, false, 1, 1, 40),
		"objectives": [
			{"type": "kill_units", "unit_ids": [10], "count": 5, "label": "用骑兵截杀 5 名敌方农民"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "先建仓库提高储存上限，再训练 4 名骑兵。绕开敌方步兵，从侧翼冲农民，不要正面硬撞。",
	}))

	out.append(_level({
		"id": "t09", "index": 9, "chapter": 3, "name": "攻城作坊",
		"type": "教学", "map_id": "ridge", "map_seed": 109,
		"time_limit": 540.0, "stars": {"two": 420.0, "three": 300.0},
		"concepts": [
			{"name": "攻城车间", "kind": "building", "id": 24, "icon": "🔨", "desc": "生产攻城车、投石车、火炮和连弩；升级车间解锁更高级攻城器。"},
			{"name": "攻城车", "kind": "unit", "id": 18, "icon": "🪵", "desc": "只拆建筑，对建筑伤害高，移动慢、怕步兵。必须有步兵掩护。"},
		],
		"unlock_units": [18],
		"unlock_buildings": [24],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 900, "wood": 1000, "stone": 800, "food": 900, "oil": 0},
			[{"id": 21, "level": 3, "offset": [-7, 5]}], 3, [], 60),
		"enemy": _e(
			[{"id": 11, "count": 4}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[],
			[
				{"id": 27, "level": 1, "offset": [-8, 0]},
				{"id": 27, "level": 1, "offset": [0, 0]},
				{"id": 27, "level": 1, "offset": [8, 0]},
				{"id": 25, "level": 1, "offset": [0, 8]},
			], false, false, 2, 1, 40),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [27], "count": 3, "label": "用攻城车拆掉 3 段城墙"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "建攻城车间，造 2 台攻城车。步兵先顶住守军，攻城车再靠近城墙输出。",
	}))

	out.append(_level({
		"id": "t10", "index": 10, "chapter": 3, "name": "叩关破城",
		"type": "进攻挑战", "map_id": "ridge", "map_seed": 110,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 8}, {"id": 12, "count": 5}, {"id": 18, "count": 2}],
			{"gold": 1000, "wood": 1200, "stone": 1000, "food": 1000, "oil": 0},
			[{"id": 21, "level": 3, "offset": [-7, 5]}, {"id": 24, "level": 1, "offset": [7, 5]}],
			3, [], 60),
		"enemy": _e(
			[{"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0},
			[],
			[
				{"id": 27, "level": 1, "offset": [-10, 0]},
				{"id": 27, "level": 1, "offset": [-5, 0]},
				{"id": 27, "level": 1, "offset": [0, 0]},
				{"id": 27, "level": 1, "offset": [5, 0]},
				{"id": 27, "level": 1, "offset": [10, 0]},
				{"id": 25, "level": 1, "offset": [-8, 8]},
				{"id": 25, "level": 1, "offset": [8, 8]},
			], true, true, 2, 1, 60),
		"objectives": [
			{"type": "destroy_castle", "label": "攻破敌方要塞主城"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "没有投石车和火炮。用步兵吸箭、弓箭手清守军、攻城车拆墙，再拆主城。",
	}))

	out.append(_level({
		"id": "t11", "index": 11, "chapter": 4, "name": "石火雷霆",
		"type": "教学", "map_id": "ridge", "map_seed": 111,
		"time_limit": 540.0, "stars": {"two": 420.0, "three": 300.0},
		"concepts": [
			{"name": "投石车", "kind": "unit", "id": 17, "icon": "🪨", "desc": "8 格射程、范围伤害，专拆建筑和密集阵型；非常怕近身。"},
			{"name": "火炮", "kind": "unit", "id": 16, "icon": "💥", "desc": "6 格射程、范围伤害，拆塔和清群都强；装填慢，需要前排保护。"},
		],
		"unlock_units": [17, 16],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 8}, {"id": 12, "count": 4}],
			{"gold": 1200, "wood": 1200, "stone": 1000, "food": 1000, "oil": 100},
			[{"id": 21, "level": 3, "offset": [-7, 5]}, {"id": 24, "level": 3, "offset": [7, 5]}],
			3, [], 60),
		"enemy": _e(
			[{"id": 11, "count": 5}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[],
			[{"id": 25, "level": 2, "offset": [-8, 4]}, {"id": 25, "level": 2, "offset": [8, 4]},
				{"id": 27, "level": 1, "offset": [0, 0]}],
			false, false, 2, 1, 40),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [25], "count": 2, "label": "用投石车/火炮摧毁 2 座箭塔"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "把攻城车间升到 3 级，各造 1 台投石车和火炮。它们射程远但很脆，步兵要顶在前面。",
	}))

	out.append(_level({
		"id": "t12", "index": 12, "chapter": 4, "name": "密林护送",
		"type": "任务挑战", "map_id": "forest", "map_seed": 112,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 8}, {"id": 12, "count": 5}, {"id": 19, "count": 2}],
			{"gold": 900, "wood": 900, "stone": 500, "food": 900, "oil": 0},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2, [], 55),
		"enemy": _e(
			[{"id": 11, "count": 4}, {"id": 12, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [], false, false, 2, 1, 40),
		"objectives": [
			{"type": "escort", "unit_id": 10, "zone": {"radius": 8.0, "offset": [0, 0]},
				"label": "护送农民工程师到中央渡口"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "信使是农民工程师，不能死。先用侦察兵探路，步兵在前、弓箭手在后，沿路清理伏兵。",
	}))

	out.append(_level({
		"id": "t13", "index": 13, "chapter": 4, "name": "争渡海峡",
		"type": "教学", "map_id": "strait", "map_seed": 113,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [
			{"name": "船坞", "kind": "building", "id": 23, "icon": "⚓", "desc": "建在水边，生产战船、运输船和炮艇；升级船坞解锁更高级舰船。"},
			{"name": "战船", "kind": "unit", "id": 13, "icon": "🚢", "desc": "水上远程单位，射程 4、血厚；怕爆破船和岸防塔，不要贴岸停。"},
		],
		"unlock_units": [13],
		"unlock_buildings": [23],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 5}, {"id": 12, "count": 3}],
			{"gold": 1000, "wood": 1200, "stone": 700, "food": 900, "oil": 100},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 2,
			[{"id": 13, "count": 2}], 55),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 25.0, "label": "敌船侦察", "water": true, "units": [{"id": 13, "count": 2}]},
				{"time": 70.0, "label": "敌船主力", "water": true, "units": [{"id": 13, "count": 3}]},
				{"time": 130.0, "label": "敌船增援", "water": true, "units": [{"id": 13, "count": 3}]},
				{"time": 190.0, "label": "敌船最后一波", "water": true, "units": [{"id": 13, "count": 4}]},
			], [], false, false, 1, 1, 40),
		"objectives": [
			{"type": "kill_units", "unit_ids": [13], "count": 4, "label": "击沉 4 艘敌船"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "在海边建船坞，补造战船。战船要成队行动，集火同一目标，别单船冲进敌群。",
	}))

	out.append(_level({
		"id": "t14", "index": 14, "chapter": 4, "name": "滩头立寨",
		"type": "教学", "map_id": "strait", "map_seed": 114,
		"time_limit": 660.0, "stars": {"two": 540.0, "three": 420.0},
		"concepts": [
			{"name": "运载船", "kind": "unit", "id": 9, "icon": "⛴️", "desc": "最多装载 8 名陆军，跨越水面；卸载前不能让部队下水。"},
			{"name": "前线城堡", "kind": "building", "id": 53, "icon": "🏯", "desc": "在敌岸建的第二主城，提供人口、生产和复活点；前置成本高但能站稳滩头。"},
		],
		"unlock_units": [9],
		"unlock_buildings": [53],
		"player": _p(
			[{"id": 10, "count": 5}, {"id": 11, "count": 8}, {"id": 12, "count": 4}],
			{"gold": 1400, "wood": 1400, "stone": 1200, "food": 1200, "oil": 150},
			[{"id": 21, "level": 2, "offset": [-7, 5]}], 4,
			[{"id": 9, "count": 1}, {"id": 13, "count": 2}], 65),
		"enemy": _e(
			[{"id": 11, "count": 4}, {"id": 12, "count": 2}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [{"id": 21, "level": 1, "offset": [0, 0]}, {"id": 25, "level": 1, "offset": [7, 5]}],
			false, false, 2, 1, 40),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [21], "count": 1, "label": "渡海登陆，摧毁敌岸兵营"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "选中运载船，把 8 名陆军装上去，渡海后在敌岸卸载。站稳后建前线城堡，再推进拆兵营。",
	}))

	out.append(_level({
		"id": "t15", "index": 15, "chapter": 4, "name": "毕业登陆",
		"type": "综合挑战", "map_id": "strait", "map_seed": 115,
		"time_limit": 720.0, "stars": {"two": 600.0, "three": 480.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 6}, {"id": 11, "count": 8}, {"id": 12, "count": 5}, {"id": 18, "count": 2}],
			{"gold": 1500, "wood": 1500, "stone": 1200, "food": 1200, "oil": 150},
			[{"id": 21, "level": 3, "offset": [-7, 5]}, {"id": 24, "level": 1, "offset": [7, 5]}],
			4, [{"id": 9, "count": 1}, {"id": 13, "count": 3}], 70),
		"enemy": _e(
			[{"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 500, "wood": 500, "stone": 300, "food": 500, "oil": 0},
			[], [{"id": 25, "level": 2, "offset": [-8, 5]}, {"id": 25, "level": 2, "offset": [8, 5]}],
			true, true, 3, 1, 60),
		"objectives": [
			{"type": "destroy_castle", "label": "渡海攻岛，摧毁敌方主城"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "战船护航运输船，把陆军送上岛，再拆主城。注意不要把所有部队挤在同一条船上。",
	}))

	# ── 进阶篇 ────────────────────────────────────────────────
	out.append(_level({
		"id": "t16", "index": 16, "chapter": 5, "name": "重装工坊",
		"type": "教学", "map_id": "desert", "map_seed": 116,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [
			{"name": "重装武器厂", "kind": "building", "id": 29, "icon": "🏭", "desc": "生产重装步兵/弓手/骑兵和巨型投石机；需要石油。本关先熟悉建筑，重装单位下一关正式登场。"},
			{"name": "长枪兵", "kind": "unit", "id": 35, "icon": "🔱", "desc": "攻击无视护甲并带小范围穿透，专门克制重装和高甲单位；怕弓箭手。"},
		],
		"unlock_units": [35],
		"unlock_buildings": [29],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 1400, "wood": 1400, "stone": 1200, "food": 1400, "oil": 400},
			[{"id": 21, "level": 4, "offset": [-7, 5]}], 4, [], 65),
		"enemy": _e(
			[{"id": 36, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [], false, false, 2, 1, 40),
		"objectives": [
			{"type": "kill_units", "unit_ids": [36], "count": 3, "label": "用长枪兵击杀 3 名重装步兵"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "重装武器厂需要石油，本关先熟悉它；主力用兵营 4 级的长枪兵，下一关才正式生产重装兵。长枪兵无视护甲，正好克制重装步兵。",
	}))

	out.append(_level({
		"id": "t17", "index": 17, "chapter": 5, "name": "重装阵线",
		"type": "教学", "map_id": "desert", "map_seed": 117,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [
			{"name": "重装步兵", "kind": "unit", "id": 36, "icon": "🛡️", "desc": "220 血、5/5 护甲，慢但硬。适合顶在最前面吸收箭矢和骑兵冲击。"},
			{"name": "重装弓箭手", "kind": "unit", "id": 37, "icon": "🏹", "desc": "高攻、6 格射程，比重弓更耐打；仍然怕骑兵贴脸，需要重步保护。"},
		],
		"unlock_units": [36, 37],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 6}],
			{"gold": 1500, "wood": 1500, "stone": 1200, "food": 1500, "oil": 500},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 29, "level": 2, "offset": [7, 5]}],
			4, [], 70),
		"enemy": _e(
			[{"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [{"id": 21, "level": 1, "offset": [0, 0]}, {"id": 25, "level": 1, "offset": [8, 5]}],
			false, false, 2, 1, 50),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [21], "count": 1, "label": "用重装阵线摧毁敌军营"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "重装步兵在前、重装弓箭手在后。不要把弓手单独推进，骑兵一贴脸就会崩。",
	}))

	out.append(_level({
		"id": "t18", "index": 18, "chapter": 5, "name": "重装突破",
		"type": "进攻挑战", "map_id": "desert", "map_seed": 118,
		"time_limit": 660.0, "stars": {"two": 540.0, "three": 420.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 6}],
			{"gold": 1600, "wood": 1600, "stone": 1400, "food": 1600, "oil": 600},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 29, "level": 2, "offset": [7, 5]}],
			4, [], 75),
		"enemy": _e(
			[{"id": 11, "count": 8}, {"id": 12, "count": 5}],
			{"gold": 600, "wood": 600, "stone": 400, "food": 600, "oil": 0},
			[], [
				{"id": 27, "level": 1, "offset": [-8, 0]},
				{"id": 27, "level": 1, "offset": [0, 0]},
				{"id": 27, "level": 1, "offset": [8, 0]},
				{"id": 25, "level": 2, "offset": [-8, 8]},
				{"id": 25, "level": 2, "offset": [8, 8]},
			], true, true, 3, 1, 60),
		"objectives": [
			{"type": "destroy_castle", "label": "用重装部队攻破要塞"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "这一关不教新单位。重装步兵顶墙、重装弓手清守军；没有重装骑兵，别想靠机动绕后。",
	}))

	out.append(_level({
		"id": "t19", "index": 19, "chapter": 5, "name": "铁骑与巨投",
		"type": "教学", "map_id": "desert", "map_seed": 119,
		"time_limit": 660.0, "stars": {"two": 540.0, "three": 420.0},
		"concepts": [
			{"name": "重装骑兵", "kind": "unit", "id": 38, "icon": "🐎", "desc": "300 血、40 攻，能冲阵吸收火力，也能追击；仍然怕长枪兵。"},
			{"name": "巨型投石机", "kind": "unit", "id": 59, "icon": "🪨", "desc": "超远射程、150 攻、范围伤害，拆城利器；移动极慢，必须重兵保护。"},
		],
		"unlock_units": [38, 59],
		"player": _p(
			[{"id": 10, "count": 8}, {"id": 11, "count": 8}, {"id": 12, "count": 4}],
			{"gold": 1800, "wood": 1800, "stone": 1600, "food": 1800, "oil": 800},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 29, "level": 3, "offset": [7, 5]}],
			4, [], 80),
		"enemy": _e(
			[{"id": 11, "count": 6}, {"id": 36, "count": 3}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [{"id": 25, "level": 2, "offset": [-9, 4]}, {"id": 25, "level": 2, "offset": [9, 4]},
				{"id": 27, "level": 1, "offset": [0, 0]}],
			false, false, 3, 1, 50),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [25], "count": 2, "label": "用巨型投石机摧毁 2 座塔"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "先把重装武器厂升到 4 级出巨型投石机，再用重装骑兵顶住反击。投石机不能单独走。",
	}))

	out.append(_level({
		"id": "t20", "index": 20, "chapter": 5, "name": "修道院",
		"type": "教学", "map_id": "forest", "map_seed": 120,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [
			{"name": "修道院", "kind": "building", "id": 54, "icon": "⛪", "desc": "生产僧侣；升级后解锁长老（按最大生命百分比伤害）和宗师（转化敌军）。"},
			{"name": "僧侣", "kind": "unit", "id": 55, "icon": "✨", "desc": "自动治疗附近伤兵，是前排的续航核心；自己没有战斗力，必须藏在后排。"},
		],
		"unlock_units": [55],
		"unlock_buildings": [54],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 8}, {"id": 12, "count": 4}],
			{"gold": 1600, "wood": 1600, "stone": 1200, "food": 1600, "oil": 200},
			[{"id": 21, "level": 4, "offset": [-7, 5]}], 4, [], 70),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 20.0, "label": "第一波", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 2}]},
				{"time": 60.0, "label": "第二波", "units": [{"id": 11, "count": 5}, {"id": 12, "count": 3}]},
				{"time": 100.0, "label": "第三波", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 3}]},
				{"time": 140.0, "label": "第四波", "units": [{"id": 11, "count": 7}, {"id": 12, "count": 4}]},
				{"time": 175.0, "label": "最后一波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}]},
			], [], false, false, 2, 1, 55),
		"objectives": [
			{"type": "survive", "duration": 180.0, "label": "用僧侣治疗前排，守住 3 分钟"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "建修道院，训练 2 名僧侣。僧侣会自动治疗附近伤兵，让他们跟着步兵主力，不要上前线。",
	}))

	out.append(_level({
		"id": "t21", "index": 21, "chapter": 5, "name": "圣所守卫",
		"type": "防守挑战", "map_id": "forest", "map_seed": 121,
		"time_limit": 420.0, "stars": {"two": 300.0, "three": 180.0},
		"concepts": [],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 55, "count": 3}],
			{"gold": 1800, "wood": 1600, "stone": 1400, "food": 1800, "oil": 300},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 54, "level": 1, "offset": [7, 5]},
				{"id": 25, "level": 2, "offset": [9, -2]}], 4, [], 80),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 20.0, "label": "第一波", "units": [{"id": 11, "count": 5}, {"id": 12, "count": 3}]},
				{"time": 75.0, "label": "第二波", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 4}]},
				{"time": 135.0, "label": "第三波", "units": [{"id": 11, "count": 7}, {"id": 12, "count": 4}, {"id": 36, "count": 2}]},
				{"time": 195.0, "label": "第四波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 5}, {"id": 36, "count": 2}]},
				{"time": 255.0, "label": "第五波", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 36, "count": 3}]},
			], [], false, false, 3, 1, 60),
		"objectives": [
			{"type": "defend_targets", "building_ids": [54], "duration": 300.0, "min_alive": 1,
				"label": "守住修道院 5 分钟"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "不能只靠箭塔。僧侣治疗前排，重装步兵顶住缺口，弓箭手集火敌方重装。修道院被拆就失败。",
	}))

	out.append(_level({
		"id": "t22", "index": 22, "chapter": 5, "name": "集市贸易",
		"type": "教学", "map_id": "classic", "map_seed": 122,
		"time_limit": 540.0, "stars": {"two": 420.0, "three": 300.0},
		"concepts": [
			{"name": "集市", "kind": "building", "id": 52, "icon": "🏪", "desc": "生产木商、石商、食商和油商；商人把资源换成黄金，再把黄金换回稀缺资源。"},
			{"name": "商人", "kind": "unit", "id": 44, "icon": "🧺", "desc": "自动往返城堡与集市。贸易路线越长单次量越大，但路上可能被截杀。"},
		],
		"unlock_units": [43, 44, 45, 51],
		"unlock_buildings": [52],
		"player": _p(
			[{"id": 10, "count": 8}, {"id": 11, "count": 5}, {"id": 12, "count": 3}],
			{"gold": 900, "wood": 1200, "stone": 800, "food": 1200, "oil": 100},
			[{"id": 21, "level": 3, "offset": [-7, 5]}], 3, [], 60),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 40.0, "label": "骚扰", "units": [{"id": 11, "count": 3}]},
				{"time": 100.0, "label": "第二次骚扰", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 2}]},
			], [], false, false, 2, 1, 40),
		"objectives": [
			{"type": "gather", "amount": 800.0, "label": "发展经济，累计获得 800 资源"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "建集市并训练商人。商人会自动跑贸易，把多余的木材/食物换成黄金和稀缺资源；记得留兵护商路。",
	}))

	out.append(_level({
		"id": "t23", "index": 23, "chapter": 5, "name": "书院官员",
		"type": "教学", "map_id": "classic", "map_seed": 123,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"concepts": [
			{"name": "书院", "kind": "building", "id": 42, "icon": "📚", "desc": "生产县吏、上校、尚书、统帅、丞相；升级书院逐级解锁更高级官员。"},
			{"name": "官员", "kind": "unit", "id": 46, "icon": "🧑‍💼", "desc": "本身不战斗，进驻仓库/兵营/城堡等建筑才生效；丞相可让同建筑其他官员加成翻倍。"},
		],
		"unlock_units": [46, 47, 48, 49, 50],
		"unlock_buildings": [42],
		"player": _p(
			[{"id": 10, "count": 8}, {"id": 11, "count": 8}, {"id": 12, "count": 4}],
			{"gold": 1800, "wood": 1800, "stone": 1400, "food": 1800, "oil": 200},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 22, "level": 1, "offset": [7, 5]}],
			4, [], 75),
		"enemy": _e(
			[], {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[
				{"time": 25.0, "label": "第一波", "units": [{"id": 11, "count": 4}, {"id": 12, "count": 2}]},
				{"time": 85.0, "label": "第二波", "units": [{"id": 11, "count": 5}, {"id": 12, "count": 3}]},
				{"time": 145.0, "label": "第三波", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 4}]},
				{"time": 205.0, "label": "第四波", "units": [{"id": 11, "count": 7}, {"id": 12, "count": 4}]},
			], [], false, false, 3, 1, 60),
		"objectives": [
			{"type": "survive", "duration": 240.0, "label": "用官员加成守住 4 分钟"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "建书院，训练县吏和上校。把县吏进驻仓库、上校进驻兵营，再守住进攻；官员不进驻就没有加成。",
	}))

	out.append(_level({
		"id": "t24", "index": 24, "chapter": 6, "name": "列国演武",
		"type": "国家试炼", "map_id": "ridge", "map_seed": 124,
		"time_limit": 600.0, "stars": {"two": 480.0, "three": 360.0},
		"nation_select": true,
		"concepts": [
			{"name": "国家特色兵", "kind": "unit", "id": 30, "icon": "⭐", "desc": "每个国家有一个专属兵种，开局前选择国家后解锁。"},
			{"name": "国家加成", "kind": "nation", "id": 0, "icon": "👑", "desc": "每个国家有全局属性/经济加成，决定整体打法。"},
		],
		"player": _p(
			[{"id": 10, "count": 7}, {"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 1600, "wood": 1600, "stone": 1200, "food": 1600, "oil": 400},
			[{"id": 21, "level": 4, "offset": [-7, 5]}, {"id": 29, "level": 2, "offset": [7, 5]}],
			4, [], 75),
		"enemy": _e(
			[{"id": 11, "count": 6}, {"id": 12, "count": 4}],
			{"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			[], [{"id": 21, "level": 1, "offset": [0, 0]}, {"id": 25, "level": 1, "offset": [8, 5]}],
			false, false, 2, 1, 50),
		"objectives": [
			{"type": "destroy_targets", "building_ids": [21], "count": 1, "label": "训练所选国家特色兵，摧毁敌方前哨"},
		],
		"fail": ["castle_lost", "timeout"],
		"brief": "选择你想体验的国家：本关会解锁该国特色兵种，并展示该国全局加成。可以反复挑战其他国家。",
	}))

	# ── 毕业演习 ──────────────────────────────────────────────
	out.append(_level({
		"id": "t25", "index": 25, "chapter": 6, "name": "联军协同",
		"type": "团队挑战", "map_id": "classic", "map_seed": 125,
		"time_limit": 900.0, "stars": {"two": 720.0, "three": 600.0},
		"multi_mode": "2v2",
		"concepts": [],
		"brief": "你与英格兰盟友对阵法兰西和中国。共享视野，和盟友夹击两座敌城；不要各自为战。",
	}))

	out.append(_level({
		"id": "t26", "index": 26, "chapter": 6, "name": "孤军奋战",
		"type": "高难挑战", "map_id": "classic", "map_seed": 126,
		"time_limit": 900.0, "stars": {"two": 720.0, "three": 600.0},
		"multi_mode": "1v2",
		"concepts": [],
		"brief": "可选高难：你独自面对蒙古和日本两个 AI。利用地形和防守反击，先拆较近的一路。",
	}))

	return out

static func all_levels() -> Array:
	var out: Array = []
	for lv in levels():
		out.append(lv.duplicate(true))
	return out

static func all_chapters() -> Array:
	return CHAPTERS.duplicate(true)

static func get_level(level_id: String, nation: int = -1) -> Dictionary:
	for lv in levels():
		if String(lv.get("id", "")) != level_id:
			continue
		var copy: Dictionary = lv.duplicate(true)
		if bool(copy.get("nation_select", false)):
			var n := int(nation)
			if n < 0:
				n = int(copy.get("player", {}).get("nation", 0))
			copy = apply_nation(copy, n)
		return copy
	return {}

# 国家试炼：替换玩家国家、特色兵概念和解锁
static func apply_nation(level: Dictionary, nation: int) -> Dictionary:
	var n := clampi(int(nation), 0, 9)
	var unit_id := int(NATION_UNITS.get(n, 30))
	var unit_name := String(EntityDatabase.get_config(unit_id).get("name", "特色兵"))
	var player: Dictionary = level.get("player", {}).duplicate(true)
	player["nation"] = n
	level["player"] = player
	var concepts: Array = level.get("concepts", []).duplicate(true)
	if concepts.size() >= 2:
		concepts[0]["name"] = unit_name
		concepts[0]["id"] = unit_id
		concepts[1]["name"] = "国家加成"
		concepts[1]["id"] = n
		concepts[1]["desc"] = NationBonuses.get_trait_full(n)
	level["concepts"] = concepts
	level["brief"] = "当前国家：%s。%s 本关会解锁 %s；体验完后可以重玩选择其他国家。" % [
		String(NATION_NAMES[n]), NationBonuses.get_trait_full(n), unit_name]
	return level

static func playable_levels() -> Array:
	var out := all_levels()
	out.sort_custom(func(a, b): return int(a.get("index", 0)) < int(b.get("index", 0)))
	return out

static func level_order(level_id: String) -> int:
	var list := playable_levels()
	for i in range(list.size()):
		if String(list[i].get("id", "")) == level_id:
			return i
	return -1

static func next_level_id(level_id: String) -> String:
	var list := playable_levels()
	var i := level_order(level_id)
	if i < 0 or i + 1 >= list.size():
		return ""
	return String(list[i + 1].get("id", ""))

static func display_name(level: Dictionary) -> String:
	var idx := int(level.get("index", 1))
	return "训练 %d · %s" % [idx, String(level.get("name", ""))]

static func main_total() -> int:
	return 25

# 第 N 关累计可用的兵种（含国家试炼的当前国家特色兵）
static func allowed_units(level_id: String, nation: int = -1) -> Array:
	var out: Array = [10]
	var seen: Dictionary = {10: true}
	for lv in playable_levels():
		for uid in lv.get("unlock_units", []):
			if not seen.has(int(uid)):
				seen[int(uid)] = true
				out.append(int(uid))
		if String(lv.get("id", "")) == level_id:
			break
	if nation >= 0 and level_id == "t24":
		var unique := int(NATION_UNITS.get(clampi(nation, 0, 9), 30))
		if not seen.has(unique):
			out.append(unique)
	# 毕业演习要展示并允许十国特色兵，避免 2v2 盟友/敌军生产被训练白名单误过滤。
	if level_id == "t25" or level_id == "t26":
		for n in NATION_UNITS:
			var uid2 := int(NATION_UNITS[n])
			if not seen.has(uid2):
				seen[uid2] = true
				out.append(uid2)
	return out

# 第 N 关累计可用的建筑（主城 20 永远可用）
static func allowed_buildings(level_id: String) -> Array:
	var out: Array = [20]
	var seen: Dictionary = {20: true}
	for lv in playable_levels():
		for bid in lv.get("unlock_buildings", []):
			if not seen.has(int(bid)):
				seen[int(bid)] = true
				out.append(int(bid))
		if String(lv.get("id", "")) == level_id:
			break
	return out

static func is_multi_level(level_id: String) -> bool:
	var lv := get_level(level_id)
	return String(lv.get("multi_mode", "")) != ""

static func multi_mode(level_id: String) -> String:
	return String(get_level(level_id).get("multi_mode", ""))

static func nation_options() -> Array:
	var out: Array = []
	for n in range(10):
		var uid := int(NATION_UNITS.get(n, 30))
		var cfg := EntityDatabase.get_config(uid)
		out.append({
			"id": n,
			"name": String(NATION_NAMES[n]),
			"unit_id": uid,
			"unit_name": String(cfg.get("name", "特色兵")),
			"bonus": NationBonuses.get_trait_full(n),
		})
	return out

static func find_nation_by_unit(unit_id: int) -> int:
	for n in NATION_UNITS:
		if int(NATION_UNITS[n]) == int(unit_id):
			return int(n)
	return -1
