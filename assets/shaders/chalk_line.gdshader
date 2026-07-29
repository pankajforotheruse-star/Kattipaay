// chalk_line.gdshader — Canvas shader for Line2D chalk rendering
// Produces a hand-drawn chalk look with:
//   - Subtle wobble along the line normal (sine displacement)
//   - Procedural noise for rough, textured edges
//   - Soft glow for lit-chalk effect
//   - Alpha fade support via uniform
//
// UV coordinate system for Godot 4 Line2D:
//   UV.x = distance along the line (0.0 at start, 1.0 at end)
//   UV.y = across the line width (0.0 at one edge, 1.0 at other edge, 0.5 at center)

shader_type canvas_item;

// Tint color — set per chalk type (white/red/yellow)
uniform vec4 chalk_color : source_color = vec4(0.95, 0.94, 0.88, 1.0);

// Wobble amplitude in pixels (scaled to UV space). 0.5-1.0 gives natural hand-drawn feel.
uniform float wobble_amplitude : hint_range(0.0, 3.0) = 0.8;

// Noise frequency for procedural edge roughness
uniform float noise_scale : hint_range(0.5, 20.0) = 4.0;

// Glow width — soft halo around the line. 0 = no glow, 2.0 = prominent glow.
uniform float glow_width : hint_range(0.0, 4.0) = 1.5;

// Overall alpha multiplier for fade animations (decoupled from color alpha)
uniform float alpha_mult : hint_range(0.0, 1.0) = 1.0;

// --- Simple hash-based pseudo-random noise ---
// Returns a value in [0, 1) that looks random but is deterministic per-pixel.
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// 2D value noise with smooth interpolation
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f); // smoothstep

	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));

	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	// Distance from line center: 0.0 at center, 1.0 at edges
	float dist_from_center = abs(UV.y - 0.5) * 2.0;

	// --- Wobble: sine displacement along local Y (across the line) ---
	// Two octaves of sine for organic feel: low-freq large wobble + high-freq texture
	float wobble_uv = wobble_amplitude * 0.008; // scale to UV units
	float wobble = sin(UV.x * 25.0 + TIME * 2.3) * wobble_uv;
	wobble += sin(UV.x * 47.0 - TIME * 1.7) * wobble_uv * 0.5;
	float adjusted_dist = dist_from_center + wobble;

	// --- Edge roughness: procedural noise ---
	// Sample noise along the line at multiple frequencies for organic texture
	float n = noise(UV * noise_scale * 40.0);
	float n_fine = noise(UV * noise_scale * 80.0 + 0.5) * 0.5;
	float roughness = (n + n_fine) * 0.2;

	// --- Core alpha: soft edge with rough boundary ---
	// Inner region (center of line) is fully opaque
	// Outer region fades to transparent, modulated by noise
	float edge_softness = 0.15; // width of the fade zone
	float inner_threshold = 0.55; // start fading at 55% from center
	float alpha_edge = 1.0 - smoothstep(inner_threshold - roughness, 1.0 + roughness + edge_softness, adjusted_dist);

	// --- Glow: soft exponential falloff beyond the line ---
	// This creates the "lit chalk" look — a subtle halo around the line
	float glow = exp(-adjusted_dist * 2.8) * 0.25 * glow_width;
	// Extra wide glow for ambiance
	float glow_wide = exp(-adjusted_dist * 1.2) * 0.06 * glow_width;

	// --- Combine alpha ---
	float combined_alpha = alpha_edge + glow + glow_wide;
	// Clamp to prevent over-brightening
	combined_alpha = min(combined_alpha, 1.0);

	// --- Apply uniforms ---
	float final_alpha = combined_alpha * alpha_mult * chalk_color.a;

	// Slight color variation along the line for hand-drawn feel
	float color_var = noise(UV * 12.0) * 0.05;
	vec3 final_color = chalk_color.rgb * (1.0 + color_var);

	COLOR = vec4(final_color, final_alpha);
}
