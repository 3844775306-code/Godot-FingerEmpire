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
#                water = true 时改在敌我之间的海面刷船（海战关）
#   navy       : 开局海军 [{id, count, level}]，船只能生活在水面，单独走水域布点
# objectives           : 任务目标：
#   {"type": "destroy_castle", "label": "…"}           摧毁敌方主城
#   {"type": "survive", "duration": 420.0, "label": "…"} 存活到倒计时结束
#   {"type": "hold_zone", "zone": {"offset":[0,0], "radius":12.0}, "hold":120.0, "label": "…"}
#                                                        占领区域累计 hold 秒
#   {"type": "escort", "unit_id":19, "zone":{"offset":[x,z],"radius":9}, "label":"…"}
#                                                        护送的指定单位活着走进目标圈
#   {"type": "destroy_targets", "building_ids":[25,26], "count":4, "label":"…"}
#                                                        摧毁敌方指定建筑 count 座
#   {"type": "gather", "amount":2500, "label":"…"}      累计采集资源量
#   {"type": "hold_zones", "zones":[{"offset":[x,z],"radius":6.5,"hold":60,"name":"西渡口"}], "label":"…"}
#                                                        同时占住多个控制区（每区独立计时）
#   {"type": "defend_targets", "building_ids":[22], "min_alive":1, "duration":360.0, "label":"…"}
#                                                        守住己方指定建筑到倒计时结束（全毁即失败）
#   {"type": "endless", "first_wave":20.0, "interval":30.0, "label":"…"}
#                                                        无限波次：波数越多敌人越强，坚持到几波就算几波
#   {"type": "kill_units", "unit_ids":[13], "count":8, "label":"…"}
#                                                        击杀指定兵种（空 = 任意）数量
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
		"desc": "穿过黑森林的伏击、夺下大河桥头、攻上台地塔阵。",
	},
	{
		"id": 3,
		"name": "第三章 · 决战",
		"desc": "封锁海峡、经营商路，最后在陨石坑边挡住敌军七波总攻。",
	},
	{
		"id": 4,
		"name": "第四章 · 帝国",
		"desc": "守住粮道、抢下双河渡口、烧掉敌军粮仓——把战争打到敌人的家门口。",
	},
	{
		"id": 5,
		"name": "挑战",
		"desc": "主线之外的试炼：海上火攻、双点争夺、无尽波次，通关主线后开放。",
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
		"subtitle": "城墙守城 · 六波进攻",
		"map_id": "ridge",
		"map_seed": 3107,
		"brief": "山脊东侧只有这一处高地，背后是断崖。\n我们已经修好一圈城墙和几座塔，但缺口来不及补。\n敌军没有营地，他们从山脊下的隘口一波波冲上来，撑到天亮就是胜利。",
		"tips": [
			"城墙南北各留了一个缺口，敌人会从缺口挤进来，把弓箭手放在缺口内侧。",
			"六波从第 1 分钟起每分钟一波，最后一波带火炮和攻城车。",
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
					"units": [{"id": 11, "count": 7}, {"id": 12, "count": 4}],
				},
				{
					"time": 120.0,
					"label": "第二波",
					"units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}, {"id": 15, "count": 2}],
				},
				{
					"time": 180.0,
					"label": "第三波",
					"units": [{"id": 11, "count": 9}, {"id": 12, "count": 6}, {"id": 15, "count": 2}],
				},
				{
					"time": 240.0,
					"label": "第四波",
					"units": [{"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 15, "count": 3}, {"id": 16, "count": 1}],
				},
				{
					"time": 300.0,
					"label": "第五波",
					"units": [{"id": 11, "count": 11}, {"id": 12, "count": 7}, {"id": 15, "count": 3}, {"id": 16, "count": 2}],
				},
				{
					"time": 360.0,
					"label": "第六波",
					"units": [
						{"id": 11, "count": 12},
						{"id": 12, "count": 8},
						{"id": 15, "count": 4},
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
			"地图中央的地面绿色色块 + 空中倒计时就是控制区，小地图上也会定时闪点。",
			"占领按人数比：我军比敌人多才计时（混战半速），双方一样就暂停，敌人多就倒退。",
			"累计占满 120 秒即胜利；主城被拆或超过 10 分钟失败。",
		],
		"time_limit": 600.0,
		"stars": {"two": 450.0, "three": 350.0},
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

	# ══════════════ 第二章 · 攻坚 ══════════════

	# ── 第 4 关：护送任务，信使活着走到哨站 ──
	{
		"id": "c2_1",
		"chapter": 2,
		"index": 4,
		"name": "黑森林伏击",
		"subtitle": "护送信使 · 穿过伏击区",
		"map_id": "forest",
		"map_seed": 6612,
		"brief": "北岭哨站的求援信必须送到。\n黑森林里到处是敌人的伏兵，信使只有一个，死了就再没有第二封。\n护着他走到地图另一头的蓝色光圈。",
		"tips": [
			"信使是队伍里头顶挂蓝色标记的侦察兵，跑得快但很脆，别让他冲在最前面。",
			"伏兵会在 1:30 / 2:30 / 3:30 / 4:30 从林子两侧杀出来，用步兵把他围在中间。",
			"信使阵亡立即失败；主城被拆或超过 7 分钟也失败。",
		],
		"time_limit": 420.0,
		"stars": {"two": 300.0, "three": 240.0},
		"player": {
			"nation": 1,
			"castle": true,
			"buildings": [
				{"id": 25, "offset": [-6.0, 6.0]},
				{"id": 25, "offset": [6.0, 6.0]},
			],
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 10},
				{"id": 12, "count": 6},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 500, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 70,
		},
		"enemy": {
			"nation": 5,
			"castle": false,
			"ai": false,
			"waves": [
				{"time": 90.0, "label": "伏兵一", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 4}]},
				{"time": 150.0, "label": "伏兵二", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}, {"id": 15, "count": 2}]},
				{"time": 210.0, "label": "伏兵三", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 6}, {"id": 15, "count": 3}]},
				{"time": 270.0, "label": "伏兵四", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 15, "count": 3}, {"id": 16, "count": 2}]},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 80,
		},
		"objectives": [
			{"type": "escort", "unit_id": 19, "zone": {"offset": [-34.0, 44.0], "radius": 9.0}, "label": "护送信使抵达北岭哨站"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ── 第 5 关：区域控制，两边都要抢桥头渡口 ──
	{
		"id": "c2_2",
		"chapter": 2,
		"index": 5,
		"name": "桥头堡",
		"subtitle": "区域控制 · 夺取渡口 90 秒",
		"map_id": "bridge",
		"map_seed": 5511,
		"brief": "十四格宽的大河把战场劈成两半，只有中央渡口能过兵。\n对面已经在对岸架起了营地，谁先占住渡口，谁的后援就能源源不断过河。\n把兵压在中央渡口，累计占满 90 秒。",
		"tips": [
			"渡口地面上的绿色色块 + 空中倒计时就是控制区（横跨桥面，圈内允许有水），小地图会定时闪点。",
			"占领按人数比：我军比敌人多才计时（混战半速），势均力敌暂停，敌人多就倒退。",
			"主城被拆或超过 15 分钟失败；累计占满 90 秒即胜利。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 480.0},
		"player": {
			"nation": 3,
			"castle": true,
			"buildings": [
				{"id": 25, "offset": [-6.0, 7.0]},
				{"id": 25, "offset": [6.0, 7.0]},
			],
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 500, "wood": 500, "stone": 350, "food": 350, "oil": 0},
			"pop_cap": 70,
		},
		"enemy": {
			"nation": 2,
			"castle": true,
			"ai": true,
			"ai_difficulty": 1,
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 500, "wood": 500, "stone": 350, "food": 350, "oil": 0},
			"pop_cap": 70,
		},
		"objectives": [
			{"type": "hold_zone", "zone": {"offset": [0.0, 0.0], "radius": 6.5}, "hold": 90.0, "label": "控制中央渡口 90 秒"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ── 第 6 关：拆塔任务，塔阵守着台地 ──
	{
		"id": "c2_3",
		"chapter": 2,
		"index": 6,
		"name": "三层台地",
		"subtitle": "攻击任务 · 拔掉 4 座防御塔",
		"map_id": "terrace",
		"map_seed": 7711,
		"brief": "敌人把营寨修在三层台地上，三面都是缓坡，正面只有四座塔在看着。\n不拔掉这些塔，攻城车还没靠近就会被点掉。\n带上火炮和攻城车，把台地上的 4 座防御塔全部拆掉。",
		"tips": [
			"火炮（16）射程比箭塔远，先用火炮点掉最外圈的塔。",
			"攻城车（18）专门拆建筑，但很脆，需要步兵在前面挡刀。",
			"4 座塔全倒即胜利；主城被拆或超过 15 分钟失败。",
		],
		"time_limit": 900.0,
		"stars": {"two": 660.0, "three": 500.0},
		"player": {
			"nation": 4,
			"castle": true,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 10},
				{"id": 12, "count": 6},
				{"id": 15, "count": 3},
				{"id": 16, "count": 2},
				{"id": 17, "count": 1},
			],
			"resources": {"gold": 600, "wood": 500, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 80,
		},
		"enemy": {
			"nation": 9,
			"castle": true,
			"ai": true,
			"ai_difficulty": 1,
			"buildings": [
				{"id": 25, "offset": [-10.0, 0.0]},
				{"id": 25, "offset": [10.0, 0.0]},
				{"id": 25, "offset": [0.0, 12.0]},
				{"id": 26, "offset": [0.0, -12.0]},
			],
			"units": [
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 500, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 70,
		},
		"objectives": [
			{"type": "destroy_targets", "building_ids": [25, 26], "count": 4, "label": "摧毁台地上的 4 座防御塔"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ══════════════ 第三章 · 决战 ══════════════

	# ── 第 7 关：海战，击沉敌船 ──
	{
		"id": "c3_1",
		"chapter": 3,
		"index": 7,
		"name": "海峡封锁",
		"subtitle": "海战 · 击沉 8 艘敌船",
		"map_id": "strait",
		"map_seed": 8811,
		"brief": "敌国的运兵船队要从海峡过去增援北线，我们只有一支小舰队和几座岸炮。\n把海面封死：击沉 8 艘敌船，他们的援军就断在海峡里。",
		"tips": [
			"开局有 4 艘战船（13）和一排岸炮，战船要主动出海拦截，别停在岸边。",
			"敌船会从第 45 秒起分批闯入海峡，共 12 艘，击沉 8 艘就完成任务。",
			"主城被毁或超过 10 分钟失败；岸炮和战船集火先打最前面那艘。",
		],
		"time_limit": 600.0,
		"stars": {"two": 420.0, "three": 330.0},
		"player": {
			"nation": 0,
			"castle": true,
			"buildings": [
				{"id": 26, "offset": [-10.0, 0.0]},
				{"id": 26, "offset": [10.0, 0.0]},
				{"id": 25, "offset": [-14.0, 8.0]},
				{"id": 25, "offset": [14.0, 8.0]},
			],
			"navy": [
				{"id": 13, "count": 4},
			],
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 600, "wood": 500, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 70,
		},
		"enemy": {
			"nation": 1,
			"castle": false,
			"ai": false,
			"waves": [
				{"time": 45.0, "label": "第一艘运兵船", "water": true, "units": [{"id": 13, "count": 2}]},
				{"time": 105.0, "label": "第二支船队", "water": true, "units": [{"id": 13, "count": 3}]},
				{"time": 165.0, "label": "第三支船队", "water": true, "units": [{"id": 13, "count": 3}]},
				{"time": 225.0, "label": "主力船队", "water": true, "units": [{"id": 13, "count": 4}]},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 80,
		},
		"objectives": [
			{"type": "kill_units", "unit_ids": [13], "count": 8, "label": "击沉 8 艘敌船"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ── 第 8 关：经济关，累计采集资源 ──
	{
		"id": "c3_2",
		"chapter": 3,
		"index": 8,
		"name": "商路争夺",
		"subtitle": "经营 · 累计采集 2500 资源",
		"map_id": "desert",
		"map_seed": 3388,
		"brief": "绿洲商路是两国最后的经济命脉。\n不需要拆掉任何人的城，只要在对方骚扰下把资源一车车运回来：累计采集 2500 资源。",
		"tips": [
			"开局有 10 个农民，优先采矿和金矿，木头够用就行。",
			"敌人会持续骚扰矿区，留 3~4 个步兵在采集点附近驻守。",
			"累计采集量只算进账，花出去的不会被扣；主城被拆或超过 15 分钟失败。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 480.0},
		"player": {
			"nation": 8,
			"castle": true,
			"units": [
				{"id": 10, "count": 10},
				{"id": 11, "count": 6},
				{"id": 12, "count": 2},
			],
			"resources": {"gold": 300, "wood": 300, "stone": 200, "food": 200, "oil": 0},
			"pop_cap": 80,
		},
		"enemy": {
			"nation": 6,
			"castle": true,
			"ai": true,
			"ai_difficulty": 1,
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 6},
				{"id": 12, "count": 3},
			],
			"resources": {"gold": 400, "wood": 400, "stone": 300, "food": 300, "oil": 0},
			"pop_cap": 70,
		},
		"objectives": [
			{"type": "gather", "amount": 2500.0, "label": "累计采集 2500 资源"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ── 第 9 关：强攻环形山要塞 ──
	{
		"id": "c3_3",
		"chapter": 3,
		"index": 9,
		"name": "环形山决战",
		"subtitle": "攻击任务 · 攻破环形山要塞",
		"map_id": "ring",
		"map_seed": 9911,
		"brief": "敌国把最后的主力缩进了环形山要塞：四座箭塔、两座炮塔，外加一圈城墙。\n我们的攻城部队已经集结完毕，这一次不谈判了，拆掉他们的主城。",
		"tips": [
			"城墙南北各有一段，东西两侧是开口，从侧翼绕进去比正面撞墙划算。",
			"敌人 AI 会出骑兵反冲，攻城车一定要留步兵保护。",
			"摧毁敌方主城即胜利；我方主城被拆或超过 20 分钟失败。",
		],
		"time_limit": 1200.0,
		"stars": {"two": 900.0, "three": 720.0},
		"player": {
			"nation": 6,
			"castle": true,
			"units": [
				{"id": 10, "count": 8},
				{"id": 11, "count": 12},
				{"id": 12, "count": 8},
				{"id": 15, "count": 4},
				{"id": 16, "count": 2},
				{"id": 17, "count": 1},
				{"id": 18, "count": 2},
			],
			"resources": {"gold": 700, "wood": 600, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 90,
		},
		"enemy": {
			"nation": 7,
			"castle": true,
			"ai": true,
			"ai_difficulty": 2,
			"buildings": [
				{"id": 25, "offset": [-12.0, -12.0]},
				{"id": 25, "offset": [12.0, -12.0]},
				{"id": 25, "offset": [-12.0, 12.0]},
				{"id": 25, "offset": [12.0, 12.0]},
				{"id": 26, "offset": [-6.0, 0.0]},
				{"id": 26, "offset": [6.0, 0.0]},
			],
			"walls": [
				{"from": [-16.0, -16.0], "to": [-4.0, -16.0]},
				{"from": [4.0, -16.0], "to": [16.0, -16.0]},
				{"from": [-16.0, 16.0], "to": [-4.0, 16.0]},
				{"from": [4.0, 16.0], "to": [16.0, 16.0]},
			],
			"units": [
				{"id": 11, "count": 10},
				{"id": 12, "count": 6},
				{"id": 15, "count": 4},
				{"id": 16, "count": 2},
			],
			"resources": {"gold": 700, "wood": 600, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 80,
		},
		"objectives": [
			{"type": "destroy_castle", "label": "摧毁环形山要塞的主城"},
		],
		"fail": ["castle_lost", "timeout"],
	},

	# ── 第 10 关：终局防守，七波总攻 ──
	{
		"id": "c3_4",
		"chapter": 3,
		"index": 10,
		"name": "陨心之战",
		"subtitle": "防守任务 · 挡住七波总攻",
		"map_id": "crater",
		"map_seed": 10011,
		"brief": "这是最后一座城。\n陨石坑边的城墙是三天前才补好的，敌人把全部家当都压上来了：七波，一波比一波狠。\n撑过 8 分钟，援军就会赶到。",
		"tips": [
			"每 1 分钟一波，第七波带 4 台火炮和 3 台攻城车，提前把攻城车集火掉。",
			"城墙东西两侧各留了一个缺口，用步兵堵口、弓箭手在墙后输出。",
			"主城被拆即失败；撑满 8 分钟胜利，主城血量越高星级越高。",
		],
		"time_limit": 0.0,
		"stars": {"two": 480.0, "three": 480.0},
		"player": {
			"nation": 2,
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
				{"from": [-14.0, -12.0], "to": [-4.0, -12.0]},
				{"from": [4.0, -12.0], "to": [14.0, -12.0]},
				{"from": [-14.0, 12.0], "to": [-4.0, 12.0]},
				{"from": [4.0, 12.0], "to": [14.0, 12.0]},
				{"from": [-14.0, -12.0], "to": [-14.0, 12.0]},
				{"from": [14.0, -12.0], "to": [14.0, 12.0]},
			],
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 10},
				{"id": 12, "count": 6},
				{"id": 16, "count": 2},
				{"id": 18, "count": 1},
			],
			"resources": {"gold": 700, "wood": 600, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 90,
		},
		"enemy": {
			"nation": 9,
			"castle": false,
			"ai": false,
			"waves": [
				{"time": 60.0, "label": "第一波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}]},
				{"time": 120.0, "label": "第二波", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 5}, {"id": 15, "count": 2}]},
				{"time": 180.0, "label": "第三波", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 6}, {"id": 15, "count": 3}, {"id": 16, "count": 1}]},
				{"time": 240.0, "label": "第四波", "units": [{"id": 11, "count": 12}, {"id": 12, "count": 6}, {"id": 15, "count": 3}, {"id": 16, "count": 2}]},
				{"time": 300.0, "label": "第五波", "units": [{"id": 11, "count": 12}, {"id": 12, "count": 8}, {"id": 15, "count": 4}, {"id": 18, "count": 2}]},
				{"time": 360.0, "label": "第六波", "units": [{"id": 11, "count": 14}, {"id": 12, "count": 8}, {"id": 15, "count": 4}, {"id": 16, "count": 3}, {"id": 18, "count": 2}]},
				{"time": 420.0, "label": "第七波", "units": [{"id": 11, "count": 16}, {"id": 12, "count": 10}, {"id": 15, "count": 5}, {"id": 16, "count": 4}, {"id": 18, "count": 3}]},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 120,
		},
		"objectives": [
			{"type": "survive", "duration": 480.0, "label": "守住 8 分钟"},
		],
		"fail": ["castle_lost"],
	},
	# ── 第 11 关：防守任务，敌人专拆粮仓，守到援军抵达 ──
	{
		"id": "c4_1",
		"chapter": 4,
		"index": 11,
		"name": "长平绝粮",
		"subtitle": "防守任务 · 守住粮仓 6 分钟",
		"map_id": "changping",
		"map_seed": 11101,
		"brief": "两山夹一谷，我军粮仓就摆在两条隘口后面。\n敌军不攻主城，只盯着粮仓打：粮仓全丢，前线立刻崩溃。\n把兵分到两处隘口，撑到援军抵达。",
		"tips": [
			"任务目标不是杀光敌人，是守住两座粮仓 6 分钟（至少保住 1 座）。",
			"敌人分两路来，两座粮仓都有危险，别把兵全堆在一边。",
			"粮仓全毁或主城被拆即失败。",
		],
		"time_limit": 480.0,
		"stars": {"two": 350.0, "three": 300.0},
		"player": {
			"nation": 3,
			"castle": true,
			"buildings": [
				{"id": 22, "offset": [-12, 10]},
				{"id": 22, "offset": [12, 10]},
				{"id": 25, "offset": [-6, 14]},
				{"id": 25, "offset": [6, 14]},
			],
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 10},
				{"id": 12, "count": 6},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 800, "wood": 600, "stone": 400, "food": 500, "oil": 0},
			"pop_cap": 80,
		},
		"enemy": {
			"nation": 5,
			"castle": false,
			"ai": false,
			"waves": [
				{"time": 30.0, "label": "前锋", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 2}]},
				{"time": 90.0, "label": "第二波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 3}, {"id": 15, "count": 2}]},
				{"time": 150.0, "label": "第三波", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 3}, {"id": 15, "count": 3}, {"id": 18, "count": 1}]},
				{"time": 210.0, "label": "第四波", "units": [{"id": 11, "count": 10}, {"id": 15, "count": 4}, {"id": 18, "count": 1}]},
				{"time": 270.0, "label": "第五波", "units": [{"id": 11, "count": 10}, {"id": 15, "count": 4}, {"id": 18, "count": 2}, {"id": 16, "count": 1}]},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 90,
		},
		"objectives": [
			{"type": "defend_targets", "building_ids": [22], "min_alive": 1, "duration": 360.0, "label": "守住粮仓到援军抵达（至少 1 座）"},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 第 12 关：双控制区任务，兵不够只能二选一 ──
	{
		"id": "c4_2",
		"chapter": 4,
		"index": 12,
		"name": "双河三岸",
		"subtitle": "双点争夺 · 两个渡口各占 60 秒",
		"map_id": "tworivers",
		"map_seed": 11404,
		"brief": "两条大河把战场切成三块，东西两处渡口是唯一的陆路通道。\n两个渡口必须都占满一分钟，分兵两线，谁也舍不得放弃任何一边。\n骑兵是唯一能在两线之间来回救火的力量。",
		"tips": [
			"两个渡口各有一个控制区，都会在地图上标出，各累计占满 60 秒才算胜利。",
			"两边同时告急时优先保住已经计时较多的一边，别来回跑空。",
			"主城被拆或超过 15 分钟失败。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 450.0},
		"player": {
			"nation": 6,
			"castle": true,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 600, "wood": 500, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 70,
		},
		"enemy": {
			"nation": 7,
			"castle": true,
			"ai": true,
			"ai_difficulty": 2,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 600, "wood": 500, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 70,
		},
		"objectives": [
			{
				"type": "hold_zones",
				"zones": [
					{"offset": [-16.0, 0.0], "radius": 6.5, "hold": 60.0, "name": "西渡口"},
					{"offset": [16.0, 0.0], "radius": 6.5, "hold": 60.0, "name": "东渡口"},
				],
				"label": "东西两个渡口各累计占领 60 秒",
			},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 第 13 关：拆敌方粮仓，敌军前线会疯狂反扑 ──
	{
		"id": "c4_3",
		"chapter": 4,
		"index": 13,
		"name": "官渡焚粮",
		"subtitle": "攻坚任务 · 摧毁敌军 3 座粮仓",
		"map_id": "guandu",
		"map_seed": 11505,
		"brief": "敌军前线全靠三座粮仓续命，粮仓就屯在主城前面。\n拆掉全部粮仓，对面的攻势就会自己垮掉。\n但敌军不会看着你拆，每一波反扑都比上一波更凶。",
		"tips": [
			"三座粮仓比主城靠前，先拆粮仓再考虑主城。",
			"敌军每隔一分半反扑一次，拆粮时别把部队全送进去。",
			"主城被拆或超过 12 分钟失败。",
		],
		"time_limit": 720.0,
		"stars": {"two": 540.0, "three": 420.0},
		"player": {
			"nation": 3,
			"castle": true,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 8},
				{"id": 12, "count": 6},
				{"id": 15, "count": 2},
				{"id": 18, "count": 1},
			],
			"resources": {"gold": 900, "wood": 700, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 80,
		},
		"enemy": {
			"nation": 5,
			"castle": true,
			"ai": true,
			"ai_difficulty": 2,
			"buildings": [
				{"id": 22, "offset": [-7, -10]},
				{"id": 22, "offset": [0, -12]},
				{"id": 22, "offset": [7, -10]},
				{"id": 25, "offset": [-10, -6]},
				{"id": 25, "offset": [10, -6]},
			],
			"units": [
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
				{"id": 15, "count": 2},
			],
			"waves": [
				{"time": 60.0, "label": "第一波反扑", "units": [{"id": 11, "count": 6}, {"id": 12, "count": 3}]},
				{"time": 150.0, "label": "第二波反扑", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 4}, {"id": 15, "count": 2}]},
				{"time": 240.0, "label": "第三波反扑", "units": [{"id": 11, "count": 9}, {"id": 12, "count": 4}, {"id": 15, "count": 3}, {"id": 18, "count": 1}]},
				{"time": 330.0, "label": "第四波反扑", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 5}, {"id": 15, "count": 3}, {"id": 18, "count": 1}]},
				{"time": 420.0, "label": "第五波反扑", "units": [{"id": 11, "count": 12}, {"id": 12, "count": 6}, {"id": 15, "count": 4}, {"id": 18, "count": 2}]},
			],
			"resources": {"gold": 800, "wood": 600, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 80,
		},
		"objectives": [
			{"type": "destroy_targets", "building_ids": [22], "count": 3, "label": "摧毁敌军 3 座粮仓"},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 第 14 关：无兵开局，只有农民和一座空城，全靠自己爆兵 ──
	{
		"id": "c4_4",
		"chapter": 4,
		"index": 14,
		"name": "巨鹿破釜",
		"subtitle": "经营任务 · 从零开始 10 分钟破城",
		"map_id": "marsh",
		"map_seed": 11202,
		"brief": "渡河之后烧掉退路，粮草只够十日。\n你手里没有一兵一卒，只有一群农民和一座空城。\n是时候把经济变成刀锋了。",
		"tips": [
			"开局没有任何军队，先造兵营、拉满人口，再出兵。",
			"资源给得不少，别舍不得花；拖到 10 分钟就是死。",
			"主城被拆或超过 10 分钟失败。",
		],
		"time_limit": 600.0,
		"stars": {"two": 420.0, "three": 330.0},
		"player": {
			"nation": 3,
			"castle": true,
			"units": [
				{"id": 10, "count": 12},
			],
			"resources": {"gold": 2000, "wood": 1500, "stone": 800, "food": 800, "oil": 0},
			"pop_cap": 100,
		},
		"enemy": {
			"nation": 2,
			"castle": true,
			"ai": true,
			"ai_difficulty": 2,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 6},
				{"id": 12, "count": 2},
			],
			"resources": {"gold": 900, "wood": 700, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 100,
		},
		"objectives": [
			{"type": "destroy_castle", "label": "10 分钟内摧毁敌方主城"},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 第 15 关：渡海登陆，敌人在中央大岛据守 ──
	{
		"id": "c4_5",
		"chapter": 4,
		"index": 15,
		"name": "海东登陆",
		"subtitle": "跨海作战 · 装船渡海，攻上敌岛",
		"map_id": "coast",
		"map_seed": 11303,
		"brief": "敌军退守中央大岛，环岛全是深水，陆军一步也过不去。\n把部队装进运载船，选一处滩头登陆，再向岛心推进。\n战船负责掩护，别让运输船半路被凿沉。",
		"tips": [
			"选中陆军、右键点自己的运载船即可登船；到对岸滩头后右键陆地卸船。",
			"运载船很脆，先让战船把敌方水面力量清掉再渡海。",
			"主城被拆、部队全灭或超过 15 分钟失败。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 480.0},
		"player": {
			"nation": 0,
			"castle": true,
			"buildings": [
				{"id": 23, "offset": [-12, 10]},
				{"id": 25, "offset": [10, 12]},
			],
			"navy": [
				{"id": 9, "count": 3},
				{"id": 13, "count": 2},
			],
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
				{"id": 15, "count": 2},
			],
			"resources": {"gold": 1200, "wood": 900, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 90,
		},
		"enemy": {
			"nation": 1,
			"castle": true,
			"ai": true,
			"ai_difficulty": 2,
			"buildings": [
				{"id": 25, "offset": [-10, 8]},
				{"id": 25, "offset": [10, 8]},
				{"id": 25, "offset": [-10, -8]},
				{"id": 25, "offset": [10, -8]},
			],
			"units": [
				{"id": 11, "count": 6},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 700, "wood": 600, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 90,
		},
		"objectives": [
			{"type": "destroy_castle", "label": "摧毁岛上的敌方主城"},
		],
		"fail": ["castle_lost", "army_wiped", "timeout"],
	},
	# ── 第 16 关：终章围歼，敌人被围但不断空降援军 ──
	{
		"id": "c4_6",
		"chapter": 4,
		"index": 16,
		"name": "垓下之围",
		"subtitle": "终章 · 围歼环山，顶住援军",
		"map_id": "gaixia",
		"map_seed": 11606,
		"brief": "敌军残部被围在环形山里，四面山口都在你手里。\n但他们不甘心，每隔一分钟就有一支援军空降山口。\n和外圈援军抢时间，在山心合围之前解决他们的主城。",
		"tips": [
			"敌人在山中据守，六个山口都有箭塔，先拔塔再进宫。",
			"每 60 秒会有一波援军从山口空降，别把攻城部队全压在城里。",
			"主城被拆或超过 20 分钟失败。",
		],
		"time_limit": 1200.0,
		"stars": {"two": 840.0, "three": 660.0},
		"player": {
			"nation": 3,
			"castle": true,
			"buildings": [
				{"id": 25, "offset": [-14, 12]},
				{"id": 25, "offset": [14, 12]},
				{"id": 26, "offset": [-8, 16]},
				{"id": 26, "offset": [8, 16]},
			],
			"units": [
				{"id": 10, "count": 6},
				{"id": 11, "count": 12},
				{"id": 12, "count": 8},
				{"id": 15, "count": 4},
				{"id": 16, "count": 2},
				{"id": 18, "count": 2},
			],
			"resources": {"gold": 1500, "wood": 1200, "stone": 900, "food": 900, "oil": 0},
			"pop_cap": 120,
		},
		"enemy": {
			"nation": 5,
			"castle": true,
			"ai": true,
			"ai_difficulty": 3,
			"buildings": [
				{"id": 25, "offset": [-10, 6]},
				{"id": 25, "offset": [10, 6]},
				{"id": 25, "offset": [-10, -6]},
				{"id": 25, "offset": [10, -6]},
				{"id": 25, "offset": [0, 12]},
				{"id": 25, "offset": [0, -12]},
			],
			"units": [
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
			],
			"waves": [
				{"time": 60.0, "label": "第一支援军", "units": [{"id": 11, "count": 8}, {"id": 12, "count": 3}]},
				{"time": 120.0, "label": "第二支援军", "units": [{"id": 11, "count": 9}, {"id": 12, "count": 3}, {"id": 15, "count": 2}]},
				{"time": 180.0, "label": "第三支援军", "units": [{"id": 11, "count": 10}, {"id": 12, "count": 4}, {"id": 15, "count": 3}, {"id": 18, "count": 1}]},
				{"time": 240.0, "label": "第四支援军", "units": [{"id": 11, "count": 12}, {"id": 12, "count": 5}, {"id": 15, "count": 3}, {"id": 18, "count": 1}]},
				{"time": 300.0, "label": "最后援军", "units": [{"id": 11, "count": 14}, {"id": 12, "count": 6}, {"id": 15, "count": 4}, {"id": 18, "count": 2}]},
			],
			"resources": {"gold": 800, "wood": 600, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 120,
		},
		"objectives": [
			{"type": "destroy_castle", "label": "摧毁被围的敌方主城"},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 挑战 2：云顶争锋，两座台地同时抢点 ──
	{
		"id": "c5_2",
		"chapter": 5,
		"index": 102,
		"name": "云顶争锋",
		"subtitle": "挑战 · 双点争夺 · 两座台地各占 60 秒",
		"map_id": "cloud_mesa",
		"map_seed": 11802,
		"brief": "五座平顶台地拔地而起，台缘全是绝壁，只有几条长坡能登顶。\n两处高地上的控制区都得占满一分钟。\n上坡慢、下坡无路，抢点就是抢坡道。",
		"tips": [
			"两个控制区分别在两座台地顶上，坡道是唯一入口，先堵坡再占点。",
			"台地视野 +25%，站上高点能提前看到敌人从哪条坡道上。",
			"主城被拆或超过 15 分钟失败。",
		],
		"time_limit": 900.0,
		"stars": {"two": 600.0, "three": 450.0},
		"player": {
			"nation": 7,
			"castle": true,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
				{"id": 15, "count": 4},
			],
			"resources": {"gold": 800, "wood": 700, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 90,
		},
		"enemy": {
			"nation": 1,
			"castle": true,
			"ai": true,
			"ai_difficulty": 3,
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 8},
				{"id": 12, "count": 4},
				{"id": 15, "count": 4},
			],
			"resources": {"gold": 800, "wood": 700, "stone": 500, "food": 500, "oil": 0},
			"pop_cap": 90,
		},
		"objectives": [
			{
				"type": "hold_zones",
				"zones": [
					{"offset": [-18.0, 0.0], "radius": 7.0, "hold": 60.0, "name": "东台"},
					{"offset": [18.0, 0.0], "radius": 7.0, "hold": 60.0, "name": "西台"},
				],
				"label": "东台、西台各累计占领 60 秒",
			},
		],
		"fail": ["castle_lost", "timeout"],
	},
	# ── 挑战 3：无尽陨心，无限波次，看你能撑到第几波 ──
	{
		"id": "c5_3",
		"chapter": 5,
		"index": 103,
		"name": "无尽陨心",
		"subtitle": "挑战 · 无尽波次 · 看你能撑到第几波",
		"map_id": "crater",
		"map_seed": 11903,
		"brief": "陨石坑里的残军被围在中心，四面八方都是敌人。\n没有增援，没有尽头，每一波都比上一波更强。\n把城守住，看看自己能撑到第几波。",
		"tips": [
			"波次一轮比一轮强，活过 5 波就有 1 星，10 波 2 星，15 波 3 星。",
			"主城一倒就结束，你的波数与得分会记进档案，下次挑战可以超过自己。",
			"别急着拆敌方——他们只是波次的来源，没有主城可拆。",
		],
		"time_limit": 0.0,
		"stars": {"two": 0.0, "three": 0.0},
		"player": {
			"nation": 3,
			"castle": true,
			"buildings": [
				{"id": 25, "offset": [-10, 10]},
				{"id": 25, "offset": [10, 10]},
				{"id": 22, "offset": [0, 14]},
			],
			"units": [
				{"id": 10, "count": 4},
				{"id": 11, "count": 8},
				{"id": 12, "count": 6},
				{"id": 15, "count": 2},
				{"id": 18, "count": 1},
			],
			"resources": {"gold": 1200, "wood": 900, "stone": 700, "food": 700, "oil": 0},
			"pop_cap": 100,
		},
		"enemy": {
			"nation": 7,
			"castle": false,
			"ai": false,
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 150,
		},
		"objectives": [
			{"type": "endless", "first_wave": 20.0, "interval": 30.0, "label": "一波接一波，撑到第 15 波"},
		],
		"fail": ["castle_lost"],
	},
	# ── 挑战 1：赤壁火攻，敌方火船成群撞岸，靠水军击沉 ──
	{
		"id": "c5_1",
		"chapter": 5,
		"index": 101,
		"name": "赤壁火攻",
		"subtitle": "挑战 · 海上火攻 · 击沉 12 艘火船",
		"map_id": "chibi",
		"map_seed": 11701,
		"brief": "长江天堑，敌军把装满柴薪的火船顺风放来，撞上岸就是一片火海。\n你手里只有六艘战船和几门岸炮，江面就是主战场。\n把火船拦在水上，一艘都别让它靠岸。",
		"tips": [
			"火船会朝岸边撞，战船要主动迎上去，别让它们贴近主城。",
			"岸炮能覆盖近岸水面，把战船的火力集中在江心。",
			"击沉 12 艘火船即胜利；主城被拆或超过 10 分钟失败。",
		],
		"time_limit": 600.0,
		"stars": {"two": 450.0, "three": 360.0},
		"player": {
			"nation": 3,
			"castle": true,
			"buildings": [
				{"id": 26, "offset": [-10, 8]},
				{"id": 26, "offset": [10, 8]},
			],
			"navy": [
				{"id": 13, "count": 6},
			],
			"units": [
				{"id": 10, "count": 4},
				{"id": 12, "count": 4},
			],
			"resources": {"gold": 800, "wood": 600, "stone": 400, "food": 400, "oil": 0},
			"pop_cap": 60,
		},
		"enemy": {
			"nation": 1,
			"castle": false,
			"ai": false,
			"waves": [
				{"time": 30.0, "label": "火船来袭", "water": true, "units": [{"id": 40, "count": 2}]},
				{"time": 75.0, "label": "第二队火船", "water": true, "units": [{"id": 40, "count": 2}]},
				{"time": 120.0, "label": "第三队火船", "water": true, "units": [{"id": 40, "count": 3}]},
				{"time": 165.0, "label": "第四队火船", "water": true, "units": [{"id": 40, "count": 3}]},
				{"time": 210.0, "label": "第五队火船", "water": true, "units": [{"id": 40, "count": 3}]},
				{"time": 255.0, "label": "最后一队火船", "water": true, "units": [{"id": 40, "count": 3}]},
			],
			"resources": {"gold": 0, "wood": 0, "stone": 0, "food": 0, "oil": 0},
			"pop_cap": 60,
		},
		"objectives": [
			{"type": "kill_units", "unit_ids": [40], "count": 12, "intercept_dist": 16.0, "max_slip": 6, "label": "击沉 12 艘敌军火船（靠岸漏过超过 6 艘即失败）"},
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

# 全部关卡（按 index 排序，跨章节统一编号）
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
	var chapter := int(level.get("chapter", 1))
	var idx := int(level.get("index", 1))
	if chapter == 5:
		return "挑战 %d · %s" % [idx - 100, String(level.get("name", ""))]
	return "第 %d 关 · %s" % [idx, String(level.get("name", ""))]
