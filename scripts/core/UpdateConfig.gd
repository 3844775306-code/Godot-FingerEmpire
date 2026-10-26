extends RefCounted

# 更新检查配置：Web / APK / EXE 都从同一个 update.json 读取最新版本和下载链接。
#
# 清单格式（UTF-8 JSON，随 Web 构建自动生成到站点根目录）：
# {
#   "version": "v1.1.0",
#   "date": "2026-11-02",
#   "notes": "一句话说明这版更新了什么",
#   "downloads": {
#     "windows": "https://github.com/.../releases/latest/download/FingerEmpire-win.zip",
#     "android": "https://github.com/.../releases/latest/download/FingerEmpire.apk",
#     "web": "https://你的站点.netlify.app/",
#     "default": "https://你的站点.netlify.app/"
#   }
# }
#
# SITE_URL 只需要在第一次部署后填一次：
#   - Web 版会自动用当前网页的 location.origin，因此即使这里还是占位符也能检查更新；
#   - APK / EXE 没有网页来源，必须填真实站点地址才能找到 update.json。
# 运行 tools/deploy_web.ps1 时，脚本会从 Netlify 读取站点地址并自动写回这里。

# 更新总开关：false = 完全不联网检查
const ENABLED: bool = true

# 站点根地址（不带结尾 /）。部署后运行 deploy 脚本会自动替换成真实地址。
const SITE_URL: String = "https://fingerempire.netlify.app"

# 最新版安装包地址：GitHub Releases 的 latest 链接，和 update.json 里保持一致。
const GITHUB_REPO_URL: String = "https://github.com/3844775306-code/Godot-FingerEmpire"
const LATEST_APK_URL: String = GITHUB_REPO_URL + "/releases/latest/download/FingerEmpire.apk"
const LATEST_WINDOWS_URL: String = GITHUB_REPO_URL + "/releases/latest/download/FingerEmpire-win.zip"

const MANIFEST_FILE: String = "update.json"

# 单次请求超时（秒）：超时视为没网，静默失败
const TIMEOUT_SEC: float = 4.0

# 检查结果缓存时间（秒）：30 分钟内不重复请求；手动点「检查更新」会强制刷新
const CACHE_TTL_SEC: int = 1800

# 规范化站点地址：去掉空白和结尾斜杠
static func normalized_site_url() -> String:
	var url: String = String(SITE_URL).strip_edges()
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url

# 是否已经配置了真实站点地址（还没有填占位符）
static func is_configured() -> bool:
	var url := normalized_site_url()
	return url != "" and not url.contains("YOUR-SITE")

# 清单完整地址；Web 优先使用当前网页的同源地址，避免依赖写死的域名。
static func manifest_url() -> String:
	if OS.has_feature("web"):
		var js = Engine.get_singleton("JavaScriptBridge")
		if js != null:
			var origin := String(js.eval("location.origin")).strip_edges()
			if origin.begins_with("http://") or origin.begins_with("https://"):
				while origin.ends_with("/"):
					origin = origin.substr(0, origin.length() - 1)
				return origin + "/" + MANIFEST_FILE
	if not is_configured():
		return ""
	return normalized_site_url() + "/" + MANIFEST_FILE

# 最新 Web 版地址（更新日志面板里的下载入口用）
static func latest_web_url() -> String:
	if is_configured():
		return normalized_site_url() + "/"
	return ""

# 更新日志面板底部展示的三个最新版本入口
static func latest_links() -> Array:
	return [
		{"label": "Web 版", "url": latest_web_url()},
		{"label": "Android APK", "url": LATEST_APK_URL},
		{"label": "Windows EXE", "url": LATEST_WINDOWS_URL},
	]
