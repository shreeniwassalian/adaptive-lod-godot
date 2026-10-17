shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx, shadows_disabled;

// UV.x runs across the river (0..1), UV.y along it (one unit per ~6 m, increasing downstream).
uniform vec3 shallow_color : source_color = vec3(0.16, 0.36, 0.33);
uniform vec3 deep_color : source_color = vec3(0.03, 0.12, 0.15);
uniform float depth_scale = 1.1;
uniform float foam_width = 0.28;
uniform float flow_speed = 0.28;
uniform float normal_strength = 0.55;
uniform sampler2D normal_a : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D normal_b : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D foam_noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

void fragment() {
	vec2 uv_a = vec2(UV.x * 3.0, UV.y * 2.0 - TIME * flow_speed);
	vec2 uv_b = vec2(UV.x * 5.0 + 0.37, UV.y * 3.3 - TIME * flow_speed * 1.45);
	vec3 n = mix(texture(normal_a, uv_a).rgb, texture(normal_b, uv_b).rgb, 0.5);
	NORMAL_MAP = n;
	NORMAL_MAP_DEPTH = normal_strength;

	float depth_raw = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth_raw);
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	scene_view.xyz /= scene_view.w;
	float thickness = max((-scene_view.z) - (-VERTEX.z), 0.0);

	float deep = clamp(thickness / depth_scale, 0.0, 1.0);
	float foam_noise_v = texture(foam_noise, uv_a * 1.7).r;
	float foam = (1.0 - smoothstep(0.0, foam_width, thickness)) * smoothstep(0.25, 0.7, foam_noise_v);

	ALBEDO = mix(mix(shallow_color, deep_color, deep), vec3(0.85), foam * 0.7);
	ALPHA = clamp(thickness * 4.0, 0.0, 1.0) * mix(0.55, 0.92, deep);
	ROUGHNESS = mix(0.04, 0.5, foam);
	SPECULAR = 0.6;
	METALLIC = 0.0;
}
