extends RefCounted

# 更新日志数据：玩家可读的改动要点，按版本倒序（最新的在最上面）。
#
# ── 发版流程 ──
#   1. 改 scripts/core/AppVersion.gd 的 VERSION / RELEASE_DATE；
#   2. 在下面 entries() 数组的最前面插一条同版本记录，items 写玩家能感知的改动；
#   3. 主菜单入口的「NEW」未读标记会自动跟着版本号走（已读记录在 user://changelog_seen.txt）。
#
# ── 写法约定 ──
#   - 每条只写玩家能感知的变化，不写技术细节、文件名、内部实现；
#   - 以「新增：」「优化：」「修复：」开头，扫一眼就知道这版有什么；
#   - 同一版本最多 8 条，次要改动合并成一条，避免列表刷太长。

# 已读版本记录文件：默认写到 user://（各平台可写目录）。
# 声明成 static var 方便调试/自动化测试临时指向别的路径（正常运行时不要改）。
static var seen_path: String = "user://changelog_seen.txt"

# 全部版本的更新日志（倒序）
static func entries() -> Array:
	return [
		{
			"version": "v1.0.1",
			"date": "2026-10-26",
			"title": "真实视野与遮挡",
			"items": [
				"新增：单位与建筑的视野受地形高度和山脊遮挡，低处看不到山脊后面的低地，视野环会按真实可见边界变成不规则形状。",
				"新增：森林会挡住视野，连续穿过两格树林就看不见后面；树林里的单位脚下两米内不受树冠遮挡。",
				"新增：单位和建筑的视野高度改为模型头顶，建筑从屋顶/烟囱高度向外看。",
				"优化：迷雾、敌方单位显示、AI 索敌、联机快照裁剪、建造预览和选中视野环统一使用同一套视野判定。",
				"优化：视野计算按视野源缓存，静止单位不会反复重算。",
				"修复：联机快照会把山脊/森林后面的敌人错误发送给客户端。",
				"新增：APK、Web、EXE 启动时自动检查版本，发现新版本可直接打开对应平台的最新下载或刷新入口。",
			],
		},
		{
			"version": "v1.0.0",
			"date": "2026-10-26",
			"title": "首个正式版本",
			"items": [
				"新增：设置面板的「相机放大倍数」滑条，默认值按设备自动适配（电脑 100%、平板 112%、手机 125%），手机和电脑都能看得舒服。",
				"新增：手机端命令栏「🔄 按住旋转」——按住按钮缓慢顺时针转动视角，松手即停；双指手势固定为缩放，不会再想缩放却把镜头带歪。",
				"新增：主菜单的「📜 更新日志」入口，随时查看当前版本与历次改动。",
				"新增：启动时自动检查有没有新版本，有的话主菜单会出现「发现新版本 · 点此下载」，直接打开下载页。",
				"优化：选中单位改为贴边发光描边，比原来的地面圆环更清楚，也不会被地形挡住。",
				"优化：建筑血条改用阵营色，FFA 模式下按各国国家色区分。",
				"修复：手机端点「联机对战」后整屏空白。",
				"修复：切换界面、攻城动画收尾、范围环与地面指引带等特殊时机的偶发报错。",
			],
		},
	]

# 最新版本号（未读判断用）
static func latest_version() -> String:
	var list: Array = entries()
	if list.is_empty():
		return ""
	return String(list[0].get("version", ""))

# 是否还没看过最新版本的日志（主菜单的 NEW 标记用它）
static func is_unseen() -> bool:
	var latest: String = latest_version()
	if latest == "":
		return false
	return _read_seen() != latest

# 记录已读版本（打开更新日志面板时调用）
static func mark_seen() -> void:
	var f := FileAccess.open(seen_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(latest_version())
	f.close()

static func _read_seen() -> String:
	if not FileAccess.file_exists(seen_path):
		return ""
	var f := FileAccess.open(seen_path, FileAccess.READ)
	if f == null:
		return ""
	var seen: String = f.get_as_text().strip_edges()
	f.close()
	return seen
