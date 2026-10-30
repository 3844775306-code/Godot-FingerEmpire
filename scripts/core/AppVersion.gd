extends RefCounted

# 游戏版本号：发版时只改这里的 VERSION / RELEASE_DATE。
# 主菜单的「📜 更新日志」入口、更新日志面板的标题都读这里，
# 不要在别处再写一份版本字符串，否则很容易和更新日志对不上。
#
# 项目没有用 git tag，导出后也读不到 git 信息（git_describe 插件只在编辑器里可用），
# 所以版本号用常量维护。版本号按「大版本 = 游戏时代」重新命名：
#   1.0.0（2026-05）球体军队 / 方块建筑，5 个开服国家，联机很卡；
#   2.0.0（2026-06）大量模型与动物、A* 寻路、商人和官员；
#   3.0.0（2026-07）混战模式、3 个新国家、Steam 联机与 UI 大改；
#   4.0.0（2026-10-25 起）画面重制、动画特效、错峰计算、Web/APK/EXE 三端与自动更新。
# 同一时代内继续用中版本/小版本记录功能批次和修复批次，历史旧版本保留在更新日志里。
const VERSION: String = "v4.0.41"
const RELEASE_DATE: String = "2026-10-30"

# 面板标题、入口按钮上显示用："v4.0.0 (2026-10-25)"
static func display() -> String:
	return "%s (%s)" % [VERSION, RELEASE_DATE]

# 只要版本号时用（未读判断、存档里的已读版本比较）
static func version() -> String:
	return VERSION
