extends RefCounted

# 闯关模式（战役）关卡数据表。
#
# 注意：本文件是 const 表，不能用 RTSConfig/GameSettings 的枚举（autoload 属性不是编译期常量），
# nation 与 ai_difficulty 一律写数字索引：nation 0维京 1英格兰 2法兰西 3中国 4匈牙利 5日本
# 6拜占庭 7蒙古 8波斯 9西班牙；ai_difficulty 0简单 1普通 2困难 3地狱。
#
# 一关 = 一张固定地图（地图预设 id + 固定随机种子）+ 双方开局配置 + 任务目标 + 时限。
# 加关卡只改这里，不需要动战斗逻辑；战役导演（CampaignDirector）按这张表生成开局。
#
# ── 字段说明 ──
# map_id / map_seed    : 地图预设（scripts/map/MapPresets.gd）与固定种子，同一关每次地形一致
# brief / tips         : 关卡简报与 3 条提示（选关界面显示）
# time_limit           : 关卡总时限（秒），0 = 不限时
# stars.two / .three   : 星级时间门槛（秒）：通关时间内 ≤ two 得 2 星、≤ three 得 3 星
# player / enemy       : 双方开局配置：
#   castle     : 是否有主城（false = 没有主城，纯军队开局）
#   ai         : 是否创建 AI 控制（false = 只用波次刷兵，敌人没有城堡也不发展）
#   buildings  : 单点建筑 [{id, offset:[dx, dz], level}]，offset 相对该方出生锚点
#   walls      : 城墙线段 [{from:[dx,dz], to:[dx,dz]}]，按墙体间距自动铺段
#   units      : 初始军队 [{id, count, level}]
#   resources  : 起始资源 {gold, wood, stone, food, oil}
#   pop_cap    : 人口上限
#   waves      : 波次表 [{time, units:[{id,count,level}], label}]，从战场上该方的来路刷出
# objectives           : 任务目标：
#   {"type": "destroy_castle", "label": "…"}           摧毁敌方主城
#   {"type": "survive", "duration": 420.0, "label": "…"} 存活到倒计时结束
#   {"type": "hold_zone", "zone": {"offset":[0,0], "radius":12.0}, "hold":120.0, "label": "…"}
#                                                        占领区域累计 hold 秒
# fail                 : 失败条件组合：army_wiped（全军覆没）/ castle_lost（主城被毁）/ timeout（超时）

const CHAPTERS := [
	{
		"id": 1,
		"name": "第一章 · 立国",
		"desc": "从一支孤军开始，学会用兵、守城与争夺要地。",
	},
	{
		"id": 2,
		"name": "第二章 · 攻坚",
		"desc": "护送、桥头堡与绿洲争夺。",
		"locked": true,
	},
	{
		"id": 3,
		"name": "第三章 · 决战",
		"desc": "群岛、台地与赤壁，帝国的最后一战。",
		"locked": true,
	},
]

const LEVELS := [
	# ── 第 1 关：攻击任务，没有主城，开局就是一支大军 ──
	{
		"id": "c1_1",
		"chapter": 1,
		"index": 1,
		"name": "渡口奇袭",
		"subtitle": "无主城 · 纯军队进攻",
		"map_id": "ford",
		"map_seed": 4021,
		"brief": "我军连夜渡河，只带得动一支轻军，没有主城也没有后勤。\n对面在白垩渡口筑起了主城和两座箭塔，正在慢慢经营。\n趁他城防还没成形，一次打穿。",
		"tips": [
			"开局就有 12 步兵 / 6 弓箭手 / 3 骑兵 / 3 攻城车，全部集中在一起。",
			"攻城车对建筑伤害极高，先让步兵扛住箭塔，再用攻城车拆主城。",
			"全军覆没而敌方主城还在，任务立即失败；没有主城就没法补兵。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 420.0},
		"player": {
			"nation": 2,
			"castle": false,
			"units": [
				{"id": 11, "count": 12},
				{"id": 12, "count": 6},
				{"id": 15, "count": 3},
				{"id": 18, "count": 3},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 80,
		},
		"enemy": {
			"nation": 1,
			"castle": true,
			"ai": true,
			"ai_difficulty": 0,
			"buildings": [
				{"id": 25, "offset": [-7.0, 6.0]},
				{"id": 25, "offset": [7.0, 6.0]},
			],
			"units": [
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 300, "wood": 300, "stone": 200, "food": 200, "oil": 0},
			"pop_cap": 60,
		},
		"objectives": [
			{"type": "destroy_castle", "label": "摧毁敌方主城"},
		],
		"fail": ["army_wiped", "timeout"],
	},

	# ── 第 2 关：防守任务，敌人没有城堡，按波次刷兵 ──
	{
		"id": "c1_2",
		"chapter": 1,
		"index": 2,
		"name": "背水一战",
		"subtitle": "城墙守城 · 三波进攻",
		"map_id": "ridge",
		"map_seed": 3107,
		"brief": "山脊东侧只有这一处高地，背后是断崖。\n我们已经修好一圈城墙和几座塔，但缺口来不及补。\n敌军没有营地，他们从山脊下的隘口一波波冲上来，撑到天亮就是胜利。",
		"tips": [
			"城墙南北各留了一个缺口，敌人会从缺口挤进来，把弓箭手放在缺口内侧。",
			"三波分别在 1 分钟 / 3 分钟 / 5 分钟抵达，最后一波带火炮和攻城车。",
			"主城被拆就失败；撑过 7 分钟即胜利，主城血量越高星级越高。",
		],
		"time_limit": 0.0,
		"stars": {"two": 420.0, "three": 420.0},
		"player": {
			"nation": 0,
			"castle": true,
			"buildings": [
				{"id": 25, "offset": [-9.0, -6.0]},
				{"id": 25, "offset": [9.0, -6.0]},
				{"id": 25, "offset": [-9.0, 6.0]},
				{"id": 25, "offset": [9.0, 6.0]},
				{"id": 26, "offset": [-4.0, -5.5]},
				{"id": 26, "offset": [4.0, 5.5]},
			],
			"walls": [
				{"from": [-12.0, -10.0], "to": [-3.0, -10.0]},
				{"from": [3.0, -10.0], "to": [12.0, -10.0]},
				{"from": [-12.0, 10.0], "to": [-3.0, 10.0]},
				{"from": [3.0, 10.0], "to": [12.0, 10.0]},
				{"from": [-12.0, -10.0], "to": [-12.0, 10.0]},
				{"from": [12.0, -10.0], "to": [12.0, 10.0]},
			],
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 500, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 70,
		},
		"enemy": {
			"nation": 1,
			"castle": false,
			"ai": false,
			"waves": [
				{
					"time": 60.0,
					"label": "第一波",
					"units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}],
				},
				{
					"time": 180.0,
					"label": "第二波",
					"units": [{"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 15, "count": 3}],
				},
				{
					"time": 300.0,
					"label": "第三波",
					"units": [
						{"id": 11, "count": 12},
						{"id": 12, "count": 8},
						{"id": 16, "count": 2},
						{"id": 18, "count": 2},
					],
				},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 80,
		},
		"objectives": [
			{"type": "survive", "duration": 420.0, "label": "守住 7 分钟"},
		],
		"fail": ["castle_lost"],
	},

	# ── 第 3 关：占领任务，双方都有主城，靠控制中央区域取胜 ──
	{
		"id": "c1_3",
		"chapter": 1,
		"index": 3,
		"name": "绿洲争夺",
		"subtitle": "区域控制 · 累计占领 120 秒",
		"map_id": "desert",
		"map_seed": 2024,
		"brief": "沙漠里只有中央绿洲能养兵。\n双方主城都缺水，谁控制绿洲超过两分钟，谁就能把对方耗死。\n把兵压在绿洲上，敌人一进来就把他们赶出去。",
		"tips": [
			"绿色圆圈是绿洲控制区：区内有我军、没有敌军时才计时。",
			"敌人进圈会让计时以两倍速倒退，别只留一两个兵守圈。",
			"累计占满 120 秒即胜利；主城被拆或超过 20 分钟失败。",
		],
		"time_limit": 1200.0,
		"stars": {"two": 900.0, "three": 700.0},
		"player": {
			"nation": 6,
			"castle": true,
			"units": [
				{"id": 10, "count": 8},
				{"id": 11, "count": 4},
				{"id": 12, "count": 2},
			],
			"resources": {"gold": 400, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 60,
		},
		"enemy": {
			"nation": 8,
			"castle": true,
			"ai": true,
			"ai_difficulty": 0,
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 4},
			],
			"resources": {"gold": 400, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 60,
		},
		"objectives": [
			{
				"type": "hold_zone",
				"zone": {"offset": [0.0, 0.0], "radius": 12.0},
				"hold": 120.0,
				"label": "占领中央绿洲 120 秒",
			},
		],
		"fail": ["castle_lost", "timeout"],
	},
]

# 全部关卡（深拷贝：调用方可安全修改返回值）
static func all_levels() -> Array:
	return LEVELS.duplicate(true)

# 全部章节
static func all_chapters() -> Array:
	return CHAPTERS.duplicate(true)

# 按 id 取关卡配置；找不到返回空字典
static func get_level(level_id: String) -> Dictionary:
	for lv in LEVELS:
		if String(lv.get("id", "")) == level_id:
			return lv.duplicate(true)
	return {}

# 第一章（当前开放的章节）内的关卡，按 index 排序
static func playable_levels() -> Array:
	var out: Array = []
	for lv in LEVELS:
		out.append(lv.duplicate(true))
	out.sort_custom(func(a, b): return int(a.get("index", 0)) < int(b.get("index", 0)))
	return out

# 关卡在整张表里的顺序下标（-1 = 不存在）
static func level_order(level_id: String) -> int:
	var list := playable_levels()
	for i in range(list.size()):
		if String(list[i].get("id", "")) == level_id:
			return i
	return -1

# 下一关 id；已是最后一关返回空串
static func next_level_id(level_id: String) -> String:
	var list := playable_levels()
	var i := level_order(level_id)
	if i < 0 or i + 1 >= list.size():
		return ""
	return String(list[i + 1].get("id", ""))

# 关卡显示名（"第 1 关 · 渡口奇袭"）
static func display_name(level: Dictionary) -> String:
	return "第 %d 关 · %s" % [int(level.get("index", 1)), String(level.get("name", ""))]
