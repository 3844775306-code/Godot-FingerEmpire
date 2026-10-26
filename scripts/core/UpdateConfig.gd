extends RefCounted

# 更新检查配置：把 MANIFEST_URL 换成你自己托管的静态 JSON 地址就启用了自动检查。
#
# 清单格式（UTF-8 JSON，放 Netlify / 自己的服务器 / GitHub raw 都行）：
# {
#   "version": "v1.1.0",
#   "date": "2026-11-02",
#   "notes": "一句话说明这版更新了什么",
#   "downloads": {
#     "windows": "https://.../FingerEmpire-win.zip",
#     "android": "https://.../FingerEmpire.apk",
#     "web": "https://.../",
#     "default": "https://.../download"
#   }
# }
#
# 发版流程：升版本号后把清单里的 version / date / 链接一并改掉；
# 游戏启动时拉一次清单（24 小时缓存），比本地版本高就在主菜单提示下载。

# 总开关：false = 完全不联网检查
const ENABLED: bool = true

# 清单地址。留空 = 不检查（代码会静默跳过，不会报错也不会拖慢启动）
const MANIFEST_URL: String = ""

# 单次请求超时（秒）：超时视为没网，静默失败
const TIMEOUT_SEC: float = 4.0

# 检查结果缓存时间（秒）：24 小时内不重复请求，避免每次启动都联网
const CACHE_TTL_SEC: int = 86400
