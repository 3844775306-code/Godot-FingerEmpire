shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

uniform vec4 water_color : source_color = vec4(0.0, 0.75, 1.0, 0.50);
uniform float time_speed : hint_range(0.1, 2.0) = 0.2;
uniform sampler2D fog_tex : source_color;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float smooth_noise(vec2 p) {
	vec2 i = floor(p); vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i+vec2(1,0)), f.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), f.x), f.y);
}
float fbm(vec2 p) {
	float v = 0.0; float a = 0.5; float f = 1.0;
	for (int i = 0; i < 4; i++) { v += a * smooth_noise(p * f); f *= 2.3; a *= 0.5; }
	return v;
}

void vertex() {
	vec3 wv = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float w = sin(wv.x * 1.8 + TIME * 0.35) * cos(wv.z * 2.2 + TIME * 0.3) * 0.04;
	w += sin(wv.x * 3.5 + TIME * 0.5) * cos(wv.z * 3.0 - TIME * 0.4) * 0.025;
	VERTEX.y += w;
}

void fragment() {
	vec2 uv_n = UV * 8.0 + vec2(TIME * time_speed * 0.3, TIME * time_speed * 0.25);
	float n = fbm(uv_n);
	vec3 col = water_color.rgb * (0.75 + n * 0.5);
	col = mix(col * 0.7, col * 1.1, smoothstep(0.3, 0.6, n));
	float spec = smoothstep(0.55, 0.7, n) * 0.3;
	float f = 1.0 - abs(dot(NORMAL, normalize(VIEW)));
	f = pow(f, 2.5);
	col += f * 0.12 * vec3(0.3, 0.6, 1.0);

	// Fog darkening
	vec4 fog = texture(fog_tex, UV);
	float fl = dot(fog.rgb, vec3(0.333));
	col = mix(col, vec3(0.05, 0.05, 0.08), 1.0 - smoothstep(0.08, 0.25, fl));

	ALBEDO = col + spec * vec3(1.0, 1.0, 1.0);
	ALPHA = mix(0.4, 0.65, f) + spec * 0.15;
	METALLIC = 0.1;
	ROUGHNESS = 0.2;
	SPECULAR = spec;
}
