shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
// Opaque grass shader shared by every grass mesh and tier (one material, no textures, no alpha).
// Mesh data: COLOR = blade colour (dark root to light tip, per-blade jitter, a few dry blades),
// UV.y = height along the blade (0 root, 1 tip). MultiMesh instance colour tints each clump.

uniform float wind_strength : hint_range(0.0, 2.0) = 1.0;
uniform float wind_speed = 1.4;
uniform vec2 wind_direction = vec2(0.8, 0.6);
uniform float root_darkening : hint_range(0.0, 1.0) = 0.3;
uniform float backlight_strength : hint_range(0.0, 1.0) = 0.35;
uniform float patch_variation : hint_range(0.0, 0.5) = 0.18;

varying float v_height;
varying vec3 v_world;

void vertex() {
	v_height = UV.y;
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world = world;
	// Travelling gust plus a faster flutter; stiff at the root, free at the tip.
	vec2 dir = normalize(wind_direction);
	float phase = dot(world.xz, dir) * 0.35 + TIME * wind_speed;
	float gust = sin(phase) * 0.6 + sin(phase * 2.3 + world.x * 0.7) * 0.4;
	float flutter = sin(TIME * wind_speed * 4.0 + world.x * 3.1 + world.z * 2.7) * 0.25;
	float bend = (gust + flutter) * wind_strength * 0.06 * v_height * v_height;
	vec3 push_world = vec3(dir.x, 0.0, dir.y) * bend;
	// World push to model space (instances are rotation plus near-uniform scale).
	float s2 = max(dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz), 1e-6);
	VERTEX += (transpose(mat3(MODEL_MATRIX)) * push_world) / s2;
}

void fragment() {
	float h = clamp(v_height, 0.0, 1.0);
	// Large, soft patches of lighter and darker grass, from world position only (deterministic).
	float patch = sin(v_world.x * 0.045 + 1.3) * sin(v_world.z * 0.052 + 0.4) + 0.5 * sin(v_world.x * 0.11 + v_world.z * 0.09);
	vec3 albedo = COLOR.rgb * (1.0 + patch * patch_variation);
	// Ambient occlusion at the roots.
	albedo *= mix(1.0 - root_darkening, 1.0, smoothstep(0.0, 0.55, h));
	ALBEDO = albedo;
	ROUGHNESS = 0.82;
	SPECULAR = 0.2;
	// Light shining through the blades from behind, strongest toward the tips.
	BACKLIGHT = albedo * vec3(1.0, 1.1, 0.5) * backlight_strength * h;
}
