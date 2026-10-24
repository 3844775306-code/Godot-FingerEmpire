shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

// 建筑受损覆盖层：用模型局部坐标生成裂纹和熏黑，作为原材质的 next_pass 叠加。
// damage: 0 = 完好，1 = 接近倒塌。
uniform float damage : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float local_scale = 1.0;
uniform vec4 crack_color : source_color = vec4(0.03, 0.025, 0.02, 1.0);
uniform vec4 soot_color : source_color = vec4(0.07, 0.065, 0.06, 1.0);

varying vec3 v_local_pos;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash31(i);
	float n100 = hash31(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash31(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash31(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash31(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash31(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash31(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash31(i + vec3(1.0, 1.0, 1.0));
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

float fbm3(vec3 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		value += amplitude * value_noise(p);
		p = p * 2.03 + vec3(13.7, 7.1, 3.3);
		amplitude *= 0.5;
	}
	return value;
}

void vertex() {
	v_local_pos = VERTEX;
}

void fragment() {
	vec3 p = v_local_pos * local_scale + vec3(seed, seed * 1.7, seed * 0.3);
	float n = fbm3(p);
	float crack_main = 1.0 - smoothstep(0.012, 0.055, abs(n - 0.5));
	float n2 = fbm3(p * 3.1 + vec3(7.0));
	float crack_fine = 1.0 - smoothstep(0.008, 0.035, abs(n2 - 0.5));
	float cracks = max(crack_main, crack_fine * 0.65);
	float soot = 0.12 + 0.08 * fbm3(p * 0.35 + vec3(3.0));
	float strength = clamp(damage, 0.0, 1.0);

	ALBEDO = mix(soot_color.rgb, crack_color.rgb, cracks);
	ALPHA = clamp(strength * (soot + cracks * 0.9), 0.0, 1.0);
}
