# scripts/data/TechTreeData.gd
# 科研模式静态数据：4 时代、56 项通用科技、10 国 × 3 项国家科技。
# 数值来自 idea/时代科技升级表_完善版.xlsx（v0.2，研究时间为原方案 1/3）。
# 本文件只描述规则，不持有对局状态；状态由 RTSBattleManager 以服务端权威方式维护。
class_name TechTreeData
extends RefCounted

const AGES: Array = [
	{"index": 0, "name": "黑暗时代", "roman": "I", "time": 0, "cost": {}, "pop": 0},
	{"index": 1, "name": "封建时代", "roman": "II", "time": 20, "cost": {"food": 600}, "pop": 20},
	{"index": 2, "name": "城堡时代", "roman": "III", "time": 30, "cost": {"gold": 500, "stone": 500}, "pop": 50},
	{"index": 3, "name": "帝国时代", "roman": "IV", "time": 40, "cost": {"gold": 500, "oil": 1000}, "pop": 80},
]

const CATEGORIES: Array = [
	{"id": "A", "name": "营造与城防"},
	{"id": "B", "name": "射术与塔防"},
	{"id": "C", "name": "步兵战阵"},
	{"id": "D", "name": "斥候与骑兵"},
	{"id": "E", "name": "航海与渡口"},
	{"id": "F", "name": "攻城与火药"},
	{"id": "G", "name": "重装军械"},
	{"id": "H", "name": "信仰与法术"},
	{"id": "I", "name": "官员与经济"},
]

const NATION_NAMES: Array = ["维京", "英格兰", "法兰西", "中国", "匈牙利", "日本", "拜占庭", "蒙古", "波斯", "西班牙"]

# 国家特色单位：nation -> unit_id
const NATION_UNIT_ID: Dictionary = {0: 30, 1: 31, 2: 32, 3: 33, 4: 34, 5: 65, 6: 66, 7: 67, 8: 68, 9: 69}
# 特色单位所需通用科技（与 06 国家特色表一致）。
const NATION_UNIT_TECH: Dictionary = {
	0: ["C2"],
	1: ["B2"],
	2: ["D2"],
	3: ["B3"],
	4: ["D3"],
	5: ["C2"],
	6: ["D4"],
	7: ["B3", "D3"],
	8: ["C3"],
	9: ["C3"],
}

# 单位类别（用于科技按类加成；同一单位可属于多个类别）
const UNIT_CLASSES: Dictionary = {
	5: ["cart"],
	6: ["trader"],
	10: ["peasant"],
	11: ["infantry"],
	12: ["archer"],
	13: ["ship"],
	14: ["ship", "peasant"],
	15: ["cavalry"],
	16: ["siege", "cannon"],
	17: ["siege", "stone"],
	18: ["siege"],
	19: ["scout"],
	30: ["infantry"],
	31: ["archer"],
	32: ["cavalry"],
	33: ["archer"],
	34: ["cavalry"],
	35: ["infantry"],
	36: ["infantry", "heavy"],
	37: ["archer", "heavy"],
	38: ["cavalry", "heavy"],
	39: ["ship", "cannon"],
	40: ["ship"],
	43: ["trader"],
	44: ["trader"],
	45: ["trader"],
	46: ["official"],
	47: ["official"],
	48: ["official"],
	49: ["official"],
	50: ["official"],
	51: ["trader"],
	55: ["caster"],
	56: ["caster"],
	57: ["caster"],
	58: ["archer"],
	59: ["siege", "stone"],
	65: ["infantry"],
	66: ["cavalry"],
	67: ["cavalry", "archer"],
	68: ["infantry"],
	69: ["infantry"],
}

const CANNON_UNIT_IDS: Array = [16, 26, 39, 64]
const STONE_UNIT_IDS: Array = [17, 59]
# 建筑 ID 范围，用于从科技 unlocks 中区分单位与建筑。
const BUILDING_IDS: Array = [7, 8, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 41, 42, 52, 53, 54, 64]

# [id, name, category, age, prereq, cost, time, effect_text, desc, unlocks, effects]
const RAW_TECHS: Array = [
	["A1", "夯土版筑", "A", 0, [], {"wood": 100}, 10, "全部建筑最大生命 +10%", "已建成与新建建筑都按比例提高最大生命，当前生命百分比不变。", [], {"building_hp_pct": 10}],
	["A2", "石基木骨", "A", 0, [], {"stone": 100}, 10, "全部建筑近战护甲 +1、盾甲 +1", "所有己方建筑生效；与 A5 的城堡/城墙加成叠加。", [], {"building_armor": 1}],
	["A3", "榫卯重修", "A", 1, ["A1"], {"gold": 100, "wood": 200}, 20, "解锁建筑修理", "信息面板出现修理按钮；修理费用与耗时沿用现有规则；主城与城堡仍不可修理。", [], {"repair_enabled": 1}],
	["A4", "石城筑法", "A", 2, ["A2", "B6"], {"gold": 200, "stone": 300}, 30, "解锁城堡", "城堡不再随时代自动解锁；需先完成 B6 烽燧望楼与 A4 石城筑法。", [53], {"castle_unlock": 1}],
	["A5", "雄城叠障", "A", 2, ["A4"], {"gold": 200, "stone": 400}, 30, "城堡与城墙最大生命 +30%，近战/盾甲 +2", "仅作用于城堡（53）与城墙（27）；与 A1、A2 叠加。", [], {"castle_wall_armor": 2, "castle_wall_hp_pct": 30}],
	["B1", "城头箭楼", "B", 0, [], {"stone": 50, "wood": 150}, 13, "主城获得箭塔级攻击：攻击 15、射程 6 米、攻速 1.2", "主城不再只能挨打；数值约等于箭塔，不随时代成长。", [], {"main_city_attack": 15, "main_city_attack_speed": 1.2, "main_city_range": 6}],
	["B2", "猎弓征募", "B", 1, [], {"food": 150, "wood": 50}, 17, "解锁弓箭手", "兵营可训练弓箭手；英格兰长弓兵同步解锁。", [12], {}],
	["B6", "烽燧望楼", "B", 1, ["B1", "B2"], {"stone": 150, "wood": 250}, 23, "解锁箭塔", "箭塔可在封建时代建造；提供固定防御与视野。", [25], {}],
	["B3", "角弓连弩", "B", 2, ["B2"], {"gold": 250, "wood": 350}, 32, "弓箭类射程 +1 米；解锁连弩", "弓箭手、长弓兵、连弩、重装弓箭手等以弓箭为子弹的单位射程 +1。", [58], {"archer_range": 1}],
	["B4", "破甲锥矢", "B", 2, ["B2"], {"gold": 400, "stone": 200}, 33, "弓箭类攻击无视目标 50% 盾甲", "对重甲目标显著；与单位自带的完全穿甲取较高值，不叠加。", [], {"archer_shield_pierce": 0.5}],
	["B5", "万箭齐发", "B", 3, ["B2"], {"gold": 400, "oil": 200, "wood": 600}, 47, "弓箭类伤害 +20%", "按基础伤害加成；与其他伤害加成相加。", [], {"class_attack_pct:archer": 20}],
	["B7", "三矢齐发", "B", 3, ["B6"], {"gold": 300, "oil": 100, "wood": 500}, 40, "主城与城堡每次攻击发射 3 支箭，每支 50% 攻击力", "单次攻击总计 150% 伤害；可分散到不同目标，目标不足时集中。只作用于主城 20 与城堡 53。", [], {"volley_count": 3, "volley_mult": 0.5}],
	["C1", "阵列操典", "C", 0, [], {"food": 100, "gold": 50}, 12, "步兵类攻击速度 +10%", "攻击间隔按 1/(1+10%) 缩短，不改变单次伤害。", [], {"class_attack_speed_pct:infantry": 10}],
	["C2", "轻装疾行", "C", 1, [], {"food": 200, "gold": 50}, 20, "步兵类移动速度 +10%", "与其他移速加成相加；软上限 +40%。", [], {"class_speed_pct:infantry": 10}],
	["C3", "盾墙拒马", "C", 2, [], {"food": 350, "stone": 150}, 28, "步兵类近战/盾甲 +1；解锁长枪兵", "长枪兵在兵营训练，对骑兵有克制；长枪兵自带完全穿甲，和 C4 取较高值。", [35], {"class_melee_armor:infantry": 1, "class_shield_armor:infantry": 1}],
	["C4", "破阵长矛", "C", 2, ["C1"], {"food": 400, "gold": 200}, 32, "步兵类攻击无视目标 50% 近战护甲", "与长枪兵自带的完全穿甲取较高值，不叠加。", [], {"class_melee_pierce:infantry": 0.5}],
	["C5", "百战精锐", "C", 3, ["C1"], {"food": 600, "gold": 400, "oil": 200}, 47, "步兵类伤害 +20%", "按基础伤害加成；与其他伤害加成相加。", [], {"class_attack_pct:infantry": 20}],
	["D1", "轻骑斥候", "D", 0, [], {"food": 100}, 10, "解锁侦察兵", "主城可训练侦察兵；高机动、低战力，用于探图与骚扰。", [19], {}],
	["D5", "围猎号令", "D", 0, [], {"food": 100}, 10, "对动物伤害 +50%", "提高猎杀羊、牛、猪的效率；农民已有巨额动物加成，不重复叠加。", [], {"animal_damage_pct": 50}],
	["D2", "牧马驯骑", "D", 1, ["D1"], {"food": 220, "gold": 100}, 22, "解锁骑兵", "兵营可训练骑兵；法兰西法式骑兵同步解锁。", [15], {}],
	["D3", "轻骑袭扰", "D", 1, ["D2"], {"food": 250, "gold": 100}, 20, "骑兵类移动速度 +10%", "与其他移速加成相加；软上限 +40%。", [], {"class_speed_pct:cavalry": 10}],
	["D4", "具装马铠", "D", 2, ["D2"], {"food": 400, "gold": 250}, 32, "骑兵类近战/盾甲 +1", "与拜占庭甲胄骑兵等国家单位的基础护甲叠加。", [], {"class_melee_armor:cavalry": 1, "class_shield_armor:cavalry": 1}],
	["E1", "栈桥飞渡", "E", 0, [], {"wood": 120}, 12, "解锁桥", "可在水面建造桥；桥使用现有通行规则。", [7], {}],
	["E2", "渔汛舟师", "E", 1, ["E1"], {"gold": 80, "wood": 180}, 18, "解锁采集船与船坞", "船坞是采集船、战船、运载船、炮艇、爆破船的生产建筑。", [14, 23], {}],
	["E3", "楼船战阵", "E", 1, ["E2", "B2"], {"gold": 150, "wood": 300}, 25, "解锁战船", "战船是封建时代的主力水面战斗单位。", [13], {}],
	["E5", "渡海征帆", "E", 1, ["E2"], {"gold": 100, "wood": 250}, 22, "解锁运载船", "运载船可运输陆军；只在靠岸时装载。", [9], {}],
	["E4", "炮舷巨舰", "E", 2, ["E3", "F2"], {"gold": 300, "oil": 100, "wood": 500}, 37, "解锁炮艇", "炮艇是城堡时代的水面重火力，受 F8/F9 炮弹科技加成。", [39], {}],
	["E6", "火舟突袭", "E", 2, ["E3", "F2"], {"gold": 300, "oil": 100, "wood": 500}, 37, "解锁爆破船", "爆破船以自爆造成范围伤害，适合冲散敌方船队。", [40], {}],
	["E7", "水寨铁甲", "E", 3, ["E3"], {"gold": 500, "oil": 300, "wood": 700}, 50, "船只最大生命 +20%，近战/盾甲 +1", "作用于采集船、战船、运载船、炮艇、爆破船。", [], {"class_hp_pct:ship": 20, "class_melee_armor:ship": 1, "class_shield_armor:ship": 1}],
	["F1", "冲车工坊", "F", 1, [], {"stone": 100, "wood": 250}, 23, "解锁攻城车间与攻城车", "攻城车间生产攻城车、火炮、投石车、巨型投石机。", [18, 24], {}],
	["F3", "投石机架", "F", 1, ["F1"], {"stone": 150, "wood": 300}, 25, "解锁投石车", "投石车是封建时代的远程攻城单位；F4/F6/F11 继续强化。", [17], {}],
	["F2", "火炮铸造", "F", 2, ["F1"], {"oil": 100, "stone": 300, "wood": 450}, 35, "解锁火炮", "火炮是城堡时代的火药攻城单位；F8/F9 继续强化。", [16], {}],
	["F4", "配重巨投", "F", 2, ["F3"], {"oil": 150, "stone": 400, "wood": 600}, 40, "解锁巨型投石机", "巨型投石机是城堡时代的重型攻城单位；F7 继续强化准度。", [59], {}],
	["F5", "冲车包铁", "F", 2, ["F1"], {"stone": 300, "wood": 400}, 30, "攻城车最大生命 +30%，近战/盾甲 +2", "让攻城车在箭塔和城墙火力下更耐打。", [], {"unit_hp_pct:18": 30, "unit_melee_armor:18": 2, "unit_shield_armor:18": 2}],
	["F6", "石弹连发", "F", 2, ["F3"], {"stone": 300, "wood": 450}, 32, "投石车攻击速度 +15%", "攻击间隔按 1/(1+15%) 缩短；不改变弹道。", [], {"unit_attack_speed_pct:17": 15}],
	["F10", "棱堡炮位", "F", 2, ["F2", "B1"], {"gold": 300, "oil": 100, "stone": 500}, 37, "解锁炮塔与墙顶炮台", "新表城堡时代的 F10；炮台只能贴城墙建造，炮塔是独立防御建筑。", [26, 64], {}],
	["F7", "望山定距", "F", 3, ["F4"], {"oil": 300, "stone": 600, "wood": 800}, 53, "巨型投石机落点误差 -30%", "新增“落点散布”属性；只对巨型投石机生效。", [], {"treb_accuracy_pct": -30}],
	["F8", "重炮装药", "F", 3, ["F2"], {"oil": 400, "stone": 500, "wood": 800}, 53, "炮弹类伤害 +30%", "火炮、炮塔、炮艇、墙顶炮台等以炮弹为弹丸的单位/建筑生效。", [], {"cannon_damage_pct": 30}],
	["F9", "加长炮管", "F", 3, ["F2"], {"oil": 400, "stone": 600, "wood": 900}, 57, "炮弹类射程 +1 米；溅射伤害由 30% 提高到 50%", "溅射比例是绝对值，不与其他溅射科技相乘。", [], {"cannon_range": 1, "cannon_splash": 50}],
	["F11", "巨石增重", "F", 3, ["F3"], {"oil": 300, "stone": 600, "wood": 800}, 40, "投石类石弹伤害 +25%，溅射半径 +20%", "新表帝王时代第二个 F10 与城堡 F10 重号，本方案将其改为 F11；只作用于投石车与巨型投石机。", [], {"stone_damage_pct": 25, "stone_splash_pct": 20}],
	["G1", "重装步军", "G", 2, ["C3"], {"food": 300, "oil": 100, "stone": 200}, 30, "解锁重装步兵与重装武器厂", "重装步兵在重装武器厂训练；按“解锁它能生产的任意一种单位”规则，重装武器厂随 G1 解锁。", [36, 29], {}],
	["G3", "重装铠甲", "G", 2, ["G1"], {"gold": 200, "oil": 100, "stone": 400}, 30, "重装单位近战/盾甲 +1", "新表 G3 为空号，本方案补为“重装铠甲”，给重装线一个防御节点。", [], {"class_melee_armor:heavy": 1, "class_shield_armor:heavy": 1}],
	["G5", "重装骑军", "G", 2, ["D4", "G1"], {"food": 400, "gold": 250, "oil": 100}, 30, "解锁重装骑兵", "重装骑兵在重装武器厂训练，定位为慢速高护甲冲击单位。", [38], {}],
	["G2", "重装弓手", "G", 3, ["B5", "G1"], {"gold": 300, "oil": 150, "wood": 400}, 40, "解锁重装弓箭手", "重装弓箭手在重装武器厂训练；吃 B 系弓箭加成与 G 系重装加成。", [37], {}],
	["G4", "重装操典", "G", 3, ["G1"], {"food": 400, "gold": 250, "oil": 100}, 40, "重装单位攻击速度 +15%", "攻击间隔按 1/(1+15%) 缩短；只作用于重装步兵/弓箭手/骑兵。", [], {"class_attack_speed_pct:heavy": 15}],
	["H1", "苦修戒律", "H", 1, [], {"food": 100, "gold": 100}, 20, "解锁僧侣与修道院", "新表 H1；僧侣在修道院训练，负责治疗友军。", [55, 54], {}],
	["H2", "长老议礼", "H", 1, ["H1"], {"food": 200, "gold": 150}, 22, "解锁长老", "长老是无视目标护甲的高阶修士，在修道院训练。", [56], {}],
	["H3", "宗师传承", "H", 2, ["H2"], {"food": 300, "gold": 250}, 30, "解锁宗师", "宗师可降低目标攻击力，并有机会招降目标；在修道院训练。", [57], {}],
	["H4", "圣礼加持", "H", 2, ["H3"], {"gold": 400, "oil": 100}, 33, "法术效果 +20%", "提高僧侣治疗量、长老伤害与宗师降攻/招降效果；具体系数由法术系统统一乘算。", [], {"spell_power_pct": 20}],
	["H5", "护法祷文", "H", 3, ["H4"], {"gold": 500, "oil": 200}, 40, "受到法术伤害 -30%，受到宗师降攻效果 -30%", "针对长老伤害与宗师降攻；招降概率是否降低由首轮测试决定，默认不受影响。", [], {"spell_resist_pct": 30}],
	["I2", "户税", "I", 1, [], {"food": 150, "wood": 100}, 20, "每 10 秒按当前人口获得黄金：人口 × 0.05", "20 人口每 10 秒 1 金，80 人口每 10 秒 4 金；与 I6 互斥，研究后 I6 永久锁定。", [], {"tax_gold": 1}],
	["I3", "独轮车", "I", 1, [], {"gold": 50, "wood": 150}, 17, "解锁手推车", "手推车在主城训练，提升搬运效率。", [5], {}],
	["I4", "商队", "I", 1, ["I3", "I5"], {"gold": 150, "wood": 200}, 25, "解锁贸易车", "贸易车在主城训练，用于远距离贸易。", [6], {}],
	["I5", "关市", "I", 1, [], {"food": 100, "gold": 200}, 20, "解锁商人与集市", "商人（油/木/石/食）在集市训练；集市随 I5 解锁。", [43, 44, 45, 51, 52], {}],
	["I1", "察举制", "I", 2, [], {"gold": 300, "stone": 200}, 30, "解锁全部官员与书院", "解锁县吏、上校、尚书、统帅、丞相；书院随 I1 解锁，官员在书院训练。", [46, 47, 48, 49, 50, 42], {}],
	["I6", "工官督造", "I", 3, ["I1"], {"food": 400, "gold": 300, "oil": 150}, 40, "全军生产速度 +20%", "新表 I6 与 I2 互斥；研究后 I2 永久锁定。只影响军事单位生产，不影响研究。", [], {"production_speed_pct": 20}],
]

# [nation, id, name, tier, age, prereq, cost, time, effect_text, desc, effects]
const RAW_NATION_TECHS: Array = [
	[0, "N01", "北地渔猎", 1, 1, [], {"food": 150, "wood": 50}, 20, "食物采集 +10%，猎杀动物 +25%", "强化维京的早期食物曲线与猎杀开局。", {"animal_damage_pct": 25, "gather_food_pct": 10}],
	[0, "N02", "狂战血誓", 2, 2, ["C2"], {"food": 350, "gold": 200}, 30, "步兵生命 +15%，狂战士攻击 +10%", "维京步兵与特色单位狂战士同时受益。", {"class_hp_pct:infantry": 15, "unit_attack_pct:30": 10}],
	[0, "N03", "卢恩铭刻", 3, 3, ["N02"], {"food": 600, "gold": 350, "oil": 150}, 40, "步兵近战/盾甲 +1，狂战士伤害 +15%", "让维京步兵在帝国时代仍保持正面强攻定位。", {"class_melee_armor:infantry": 1, "class_shield_armor:infantry": 1, "unit_attack_pct:30": 15}],
	[1, "N04", "舍伍德猎场", 1, 1, [], {"gold": 50, "wood": 150}, 20, "木材采集 +10%，弓箭手视野 +10%", "强化英格兰的木材经济与远程视野优势。", {"class_vision_pct:archer": 10, "gather_wood_pct": 10}],
	[1, "N05", "长弓破阵", 2, 2, ["B2"], {"gold": 250, "wood": 350}, 30, "长弓兵/弓箭手攻击 +10%，对建筑伤害 +20%", "让长弓兵在攻城时也有存在感，但不替代攻城器。", {"class_attack_pct:archer": 10, "class_building_damage_pct:archer": 20}],
	[1, "N06", "王国防线", 3, 3, ["N05"], {"gold": 200, "stone": 400, "wood": 600}, 40, "箭塔/城堡攻速 +20%，主城/城堡射程 +1", "强化英格兰的阵地战与防守反击。", {"main_castle_range": 1, "tower_attack_speed_pct": 20}],
	[2, "N07", "采邑骑士", 1, 1, [], {"food": 200, "gold": 100}, 20, "骑兵生命 +10%，训练时间 -15%", "法兰西开局骑兵更耐打、更快成型。", {"class_hp_pct:cavalry": 10, "class_training_speed_pct:cavalry": 15}],
	[2, "N08", "铁骑冲锋", 2, 2, ["D2"], {"food": 400, "gold": 250}, 30, "骑兵攻击 +15%，对弓箭类伤害 +20%", "强化法兰西骑兵对远程部队的压制。", {"class_attack_pct:cavalry": 15, "class_vs_archer_pct:cavalry": 20}],
	[2, "N09", "百合王旗", 3, 3, ["N08"], {"food": 700, "gold": 400, "oil": 150}, 40, "骑兵近战/盾甲 +1，城堡攻击 +20%", "让法兰西的骑兵与城堡形成终局支点。", {"building_attack_pct:53": 20, "class_melee_armor:cavalry": 1, "class_shield_armor:cavalry": 1}],
	[3, "N10", "井田劝农", 1, 1, [], {"food": 150, "wood": 100}, 20, "农田食物 +15%，农民移速 +10%", "强化中国粮食经济与农民调度。", {"gather_food_pct": 15, "unit_speed_pct:10": 10}],
	[3, "N11", "连弩机括", 2, 2, ["B3"], {"gold": 300, "wood": 400}, 30, "连弩/诸葛连弩攻速 +15%，伤害 +10%", "强化中国连弩的持续输出。", {"unit_attack_pct:33": 10, "unit_attack_pct:58": 10, "unit_attack_speed_pct:33": 15, "unit_attack_speed_pct:58": 15}],
	[3, "N12", "长城烽燧", 3, 3, ["N11"], {"gold": 300, "oil": 150, "stone": 600}, 40, "城墙/城堡生命 +20%，箭塔射程 +1", "强化中国的城防与塔防体系。", {"building_hp_pct:27": 20, "building_hp_pct:53": 20, "tower_range": 1}],
	[4, "N13", "喀尔巴阡牧马", 1, 1, [], {"food": 200, "gold": 50}, 20, "骑兵移速 +10%，训练时间 -10%", "强化匈牙利骑兵的机动与成型速度。", {"class_speed_pct:cavalry": 10, "class_training_speed_pct:cavalry": 10}],
	[4, "N14", "象背战堡", 2, 2, ["D3"], {"food": 450, "gold": 250}, 30, "象骑兵生命 +20%，伤害 +15%", "让象骑兵成为匈牙利的重型前排。", {"unit_attack_pct:34": 15, "unit_hp_pct:34": 20}],
	[4, "N15", "多瑙河防线", 3, 3, ["N14"], {"gold": 300, "oil": 150, "stone": 600}, 40, "城堡/箭塔生命 +20%，骑兵护甲 +1", "强化匈牙利防守与骑兵生存。", {"building_hp_pct:25": 20, "building_hp_pct:53": 20, "class_melee_armor:cavalry": 1}],
	[5, "N16", "刀匠锻冶", 1, 1, [], {"food": 150, "gold": 100}, 20, "步兵攻击 +10%，训练时间 -15%", "强化日本步兵的早期压制。", {"class_attack_pct:infantry": 10, "class_training_speed_pct:infantry": 15}],
	[5, "N17", "武士道", 2, 2, ["C2"], {"food": 400, "gold": 250}, 30, "日本武士/步兵攻速 +15%，生命 +10%", "强化日本武士的爆发与持续作战。", {"class_attack_speed_pct:infantry": 15, "class_hp_pct:infantry": 10, "unit_attack_speed_pct:65": 15}],
	[5, "N18", "天守阁", 3, 3, ["N17"], {"gold": 250, "stone": 400, "wood": 600}, 40, "城堡生命 +30%，主城/城堡攻击 +20%", "强化日本城堡的终局防守。", {"building_hp_pct:53": 30, "main_castle_attack_pct": 20}],
	[6, "N19", "希腊火", 1, 1, ["E3"], {"gold": 150, "wood": 250}, 20, "战船攻击 +20%，对船只伤害 +20%", "强化拜占庭的海战火力；陆图可跳过。", {"unit_attack_pct:13": 20, "unit_vs_ship_pct:13": 20}],
	[6, "N20", "甲胄具装", 2, 2, ["D4"], {"food": 400, "gold": 300}, 30, "甲胄骑兵/重装骑兵护甲 +1/+1，生命 +10%", "强化拜占庭重装骑兵的防御。", {"unit_hp_pct:38": 10, "unit_hp_pct:66": 10, "unit_melee_armor:38": 1, "unit_melee_armor:66": 1, "unit_shield_armor:38": 1, "unit_shield_armor:66": 1}],
	[6, "N21", "狄奥多西城墙", 3, 3, ["N20"], {"gold": 400, "oil": 150, "stone": 700}, 40, "城墙/城堡生命 +30%，修理费用 -25%", "强化拜占庭的城防与持久战。", {"building_hp_pct:27": 30, "building_hp_pct:53": 30, "repair_cost_pct": -25}],
	[7, "N22", "草原牧群", 1, 1, [], {"food": 200, "gold": 50}, 20, "食物采集 +10%，骑兵移速 +10%", "强化蒙古的早期机动与食物经济。", {"class_speed_pct:cavalry": 10, "gather_food_pct": 10}],
	[7, "N23", "骑射旋风", 2, 2, ["B3", "D3"], {"food": 400, "gold": 300}, 30, "蒙古弓骑/骑射单位攻击 +15%，移速 +10%", "蒙古弓骑同时需要 B3 与 D3，符合其复合定位。", {"class_attack_pct:cavalry": 15, "unit_attack_pct:67": 15, "unit_speed_pct:67": 10}],
	[7, "N24", "金帐西征", 3, 3, ["N23"], {"food": 700, "gold": 400, "oil": 200}, 40, "骑兵/骑射单位生命 +15%，视野 +20%", "强化蒙古的终局机动与生存。", {"class_hp_pct:archer": 15, "class_hp_pct:cavalry": 15, "class_vision_pct:cavalry": 20}],
	[8, "N25", "坎儿井灌渠", 1, 1, [], {"food": 200, "gold": 50}, 20, "农民采集效率 +10%，人口上限 +5", "强化波斯的经济发展与人口规模。", {"gather_all_pct": 10, "pop_bonus": 5}],
	[8, "N26", "长生军阵", 2, 2, ["C3"], {"food": 450, "gold": 250}, 30, "长生军/步兵生命 +15%，近战/盾甲 +1", "强化波斯长生军与步兵前排。", {"class_hp_pct:infantry": 15, "class_melee_armor:infantry": 1, "class_shield_armor:infantry": 1}],
	[8, "N27", "御道驿传", 3, 3, ["N26"], {"food": 300, "gold": 600, "oil": 150}, 40, "全军移速 +10%，商人/贸易车收益 +20%", "强化波斯的机动与经济。", {"all_speed_pct": 10, "trade_income_pct": 20}],
	[9, "N28", "边境拓殖", 1, 1, [], {"food": 200, "wood": 100}, 20, "食物/木材采集 +10%，农民建造速度 +10%", "强化西班牙的早期扩张。", {"construction_speed_pct": 10, "gather_food_pct": 10, "gather_wood_pct": 10}],
	[9, "N29", "方阵枪林", 2, 2, ["C3"], {"food": 400, "gold": 250}, 30, "方阵兵/长枪兵护甲 +1，对骑兵伤害 +20%", "强化西班牙方阵的反骑兵定位。", {"class_vs_cavalry_pct:infantry": 20, "unit_melee_armor:35": 1, "unit_melee_armor:69": 1, "unit_shield_armor:35": 1, "unit_shield_armor:69": 1}],
	[9, "N30", "黄金船队", 3, 3, ["N29"], {"gold": 600, "oil": 150, "wood": 300}, 40, "贸易/商队收益 +25%，船只生命 +15%", "强化西班牙的贸易与海军。", {"class_hp_pct:ship": 15, "trade_income_pct": 25}],
]


static var _techs: Dictionary = {}
static var _nation_techs: Dictionary = {}
static var _tech_order: Array = []
static var _bits: Dictionary = {}

static func _ensure() -> void:
	if not _techs.is_empty():
		return
	_tech_order.clear()
	_bits.clear()
	for i in range(RAW_TECHS.size()):
		var row: Array = RAW_TECHS[i]
		var tech: Dictionary = {
			"id": row[0], "name": row[1], "category": row[2], "age": int(row[3]),
			"prereq": row[4], "cost": row[5], "time": int(row[6]),
			"effect_text": row[7], "desc": row[8], "unlocks": row[9], "effects": row[10],
			"kind": "tech",
		}
		_techs[tech["id"]] = tech
		_tech_order.append(tech["id"])
		_bits[tech["id"]] = i
	for row in RAW_NATION_TECHS:
		var nt: Dictionary = {
			"id": row[1], "name": row[2], "tier": int(row[3]), "age": int(row[4]),
			"prereq": row[5], "cost": row[6], "time": int(row[7]),
			"effect_text": row[8], "desc": row[9], "effects": row[10],
			"nation": int(row[0]), "unlocks": [], "category": "N", "kind": "nation",
		}
		_nation_techs[nt["id"]] = nt

static func tech_ids() -> Array:
	_ensure()
	return _tech_order.duplicate()

static func all_techs() -> Array:
	_ensure()
	var out: Array = []
	for tid in _tech_order:
		out.append(_techs[tid])
	return out

static func get_tech(tid: String) -> Dictionary:
	_ensure()
	return _techs.get(tid, {}).duplicate(true)

static func get_any(tid: String) -> Dictionary:
	_ensure()
	if _techs.has(tid):
		return _techs[tid].duplicate(true)
	if _nation_techs.has(tid):
		return _nation_techs[tid].duplicate(true)
	return {}

static func nation_techs(nation: int) -> Array:
	_ensure()
	var out: Array = []
	for t in _nation_techs.values():
		if int(t.get("nation", -1)) == nation:
			out.append(t)
	out.sort_custom(func(a, b): return int(a["tier"]) < int(b["tier"]))
	return out

static func tech_bit(tid: String) -> int:
	_ensure()
	return int(_bits.get(tid, -1))

static func has_bit(bits: int, tid: String) -> bool:
	var b := tech_bit(tid)
	return b >= 0 and (bits & (1 << b)) != 0

static func set_bit(bits: int, tid: String) -> int:
	var b := tech_bit(tid)
	return bits | (1 << b) if b >= 0 else bits

static func nation_bit(nation: int, tid: String) -> int:
	var list := nation_techs(nation)
	for i in range(list.size()):
		if String(list[i]["id"]) == tid:
			return i
	return -1

static func has_nation_bit(mask: int, nation: int, tid: String) -> bool:
	var b := nation_bit(nation, tid)
	return b >= 0 and (mask & (1 << b)) != 0

static func set_nation_bit(mask: int, nation: int, tid: String) -> int:
	var b := nation_bit(nation, tid)
	return mask | (1 << b) if b >= 0 else mask

static func unit_has_class(uid: int, cls: String) -> bool:
	return cls in UNIT_CLASSES.get(uid, [])

static func collect_mods(bits: int, nation_mask: int, nation: int) -> Dictionary:
	_ensure()
	var mods: Dictionary = {}
	for tid in _tech_order:
		if not has_bit(bits, tid):
			continue
		_merge_effects(mods, _techs[tid].get("effects", {}))
	for t in nation_techs(nation):
		if has_nation_bit(nation_mask, nation, String(t["id"])):
			_merge_effects(mods, t.get("effects", {}))
	return mods

static func _merge_effects(mods: Dictionary, effects: Dictionary) -> void:
	for key in effects:
		var v = effects[key]
		if v is int or v is float:
			mods[key] = float(mods.get(key, 0.0)) + float(v)

static func unlocked_units(bits: int, nation_mask: int, nation: int) -> Dictionary:
	_ensure()
	var out: Dictionary = {10: true, 11: true}
	for tid in _tech_order:
		if not has_bit(bits, tid):
			continue
		for uid in _techs[tid].get("unlocks", []):
			if not (int(uid) in BUILDING_IDS):
				out[int(uid)] = true
	var nu: int = int(NATION_UNIT_ID.get(nation, -1))
	if nu >= 0 and nation_unit_unlocked(bits, nation):
		out[nu] = true
	return out

static func unlocked_buildings(bits: int, nation_mask: int, nation: int) -> Dictionary:
	_ensure()
	var out: Dictionary = {20: true, 21: true, 22: true, 27: true, 28: true, 41: true, 8: true}
	for tid in _tech_order:
		if not has_bit(bits, tid):
			continue
		for uid in _techs[tid].get("unlocks", []):
			if (uid >= 20 and uid < 30) or uid in [41, 42, 52, 53, 54, 64]:
				out[int(uid)] = true
	return out

static func nation_unit_unlocked(bits: int, nation: int) -> bool:
	_ensure()
	var req: Array = NATION_UNIT_TECH.get(nation, [])
	if req.is_empty():
		return false
	for tid in req:
		if not has_bit(bits, tid):
			return false
	return true

static func is_age_tech(tid: String) -> bool:
	return tid.begins_with("AGE_")

static func age_of(tid: String) -> int:
	if tid.begins_with("AGE_"):
		return int(tid.substr(4))
	var t := get_any(tid)
	return int(t.get("age", 0))

static func effect_summary(tid: String) -> String:
	var t := get_any(tid)
	return String(t.get("effect_text", ""))

static func get_age(index: int) -> Dictionary:
	return AGES[clampi(index, 0, AGES.size() - 1)].duplicate(true)

static func age_name(index: int) -> String:
	return String(get_age(index).get("name", ""))

static func next_age(index: int) -> Dictionary:
	if index < 0 or index >= AGES.size() - 1:
		return {}
	return get_age(index + 1)

static func techs_for_age(age: int) -> Array:
	_ensure()
	var out: Array = []
	for t in _techs.values():
		if int(t.get("age", 0)) == age:
			out.append(t)
	return out
