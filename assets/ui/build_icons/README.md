# 建造菜单图标（build_icons）

建造菜单用到的建筑缩略图，`<建筑id>.png` 与 `EntityDatabase` 里的建筑 id 一一对应。

- 尺寸：256×256 透明底 PNG，模型等比缩放到底边对齐，带一层椭圆软阴影；
- 生成脚本：`tools/render_build_icons.gd` + `tools/render_build_icons.tscn`；
- 重新生成（新增建筑或换模型后跑一次，然后重新导入资源并提交）：

```powershell
D:\...\Godot_v4.7.2-stable_win64_console.exe --path <项目根> res://tools/render_build_icons.tscn
```

生成脚本里的 `BUILDING_IDS` 需要同步加上新建筑 id。
