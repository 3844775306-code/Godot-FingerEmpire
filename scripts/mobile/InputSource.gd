class_name InputSource
extends RefCounted

# 输入源判定：统一替代散落在各脚本里的 OS.has_feature 判断。
# 项目里原有三处零散判断，此处收敛后新增的移动端 UI 只依赖这一个入口。

# 开发期开关：桌面端用 `-- --mobile-ui` 启动即可预览触屏界面
static var force_mobile_ui: bool = false
static var _web_touch_logged: bool = false

# 是否移动平台（导出目标本身是手机/平板）
static func is_mobile_platform() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("android") or OS.has_feature("ios")

# 是否触屏设备（含 Windows 触屏本，方便开发期用触摸屏验证）
static func is_touch() -> bool:
	if is_mobile_platform():
		return true
	return DisplayServer.is_touchscreen_available()

# 是否启用移动版 UI：移动平台、Web 触屏设备，或开发期强制开关。
# 桌面触屏本仍走桌面 UI——这类设备通常配鼠标键盘，桌面布局信息密度更合适。
# Web 版在 iPad/手机上打开时没有 mobile/android/ios 特性，只能通过触屏能力判断。
static func use_mobile_ui() -> bool:
	if force_mobile_ui or is_mobile_platform():
		return true
	if OS.has_feature("web"):
		var touch := DisplayServer.is_touchscreen_available()
		if not touch:
			# 部分 iPad/移动浏览器只暴露 maxTouchPoints，不提供 DisplayServer 触摸能力。
			var js = Engine.get_singleton("JavaScriptBridge")
			if js != null:
				touch = bool(js.eval("navigator.maxTouchPoints > 0 || 'ontouchstart' in window"))
		if not _web_touch_logged:
			_web_touch_logged = true
			print("[InputSource] web touch=", touch, " mobile_ui=", touch)
		return touch
	return false

# 供日志/调试面板显示
static func device_kind() -> String:
	if OS.has_feature("android"):
		return "android"
	if OS.has_feature("ios"):
		return "ios"
	if OS.has_feature("web"):
		return "web"
	return "desktop" + ("-touch" if DisplayServer.is_touchscreen_available() else "")
