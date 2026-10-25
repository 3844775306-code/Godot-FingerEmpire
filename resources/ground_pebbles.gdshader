shader_type spatial;
// 地面碎石材质：只负责把低多边形碎石块按地形雾图压暗，
// 这样碎石不会在未探索的黑色迷雾里露出来。
// 不用任何贴图做碎石本身，形状全部来自 MultiMesh 的低多边形网格。
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform sampler2D fog_tex : source_color, filter_linear;
uniform float map_size : hint_range(1.0, 512.0) = 100.0;
uniform vec3 stone_color : source_color = vec3(0.50, 0.47, 0.41);

void fragment() {
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = wpos.xz / map_size + vec2(0.5);
	vec3 ground = texture(fog_tex, uv).rgb;
	// 可见区域地形较亮，碎石保持石材色；迷雾区域地形很暗，碎石随之下沉。
	// 用 smoothstep 拉开明暗差，否则石头的灰色和草地灰绿色糊在一起。
	float brightness = max(ground.r, max(ground.g, ground.b));
	float light = smoothstep(0.08, 0.32, brightness);
	ALBEDO = stone_color * light;
	// 石头背光面容易黑成小洞，给一点同色自发光把暗部拉回来。
	EMISSION = stone_color * light * 0.08;
	ROUGHNESS = 1.0;
	SPECULAR = 0.12;
}
