extends RefCounted

# 游戏版本号：发版时只改这里的 VERSION / RELEASE_DATE。
# 主菜单的「📜 更新日志」入口、更新日志面板的标题都读这里，
# 不要在别处再写一份版本字符串，否则很容易和更新日志对不上。
#
# 项目没有用 git tag，导出后也读不到 git 信息（git_describe 插件只在编辑器里可用），
# 所以版本号用常量维护；版本历史按 tools/bump_version.ps1 的规则从 1.0.0 折算。
const VERSION: String = "v1.6.52"
const RELEASE_DATE: String = "2026-10-27"

# 面板标题、入口按钮上显示用："v1.6.49 (2026-10-26)"
static func display() -> String:
	return "%s (%s)" % [VERSION, RELEASE_DATE]

# 只要版本号时用（未读判断、存档里的已读版本比较）
static func version() -> String:
	return VERSION
