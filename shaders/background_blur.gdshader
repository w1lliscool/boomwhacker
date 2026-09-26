shader_type canvas_item;

uniform float blur_px : hint_range(0.0, 12.0) = 0.0;

const int SAMPLES = 8;

float gauss(float x, float sigma) {
	return exp(-(x * x) / (2.0 * sigma * sigma));
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec4 col = base;
	if (blur_px >= 0.5) {
		float step_px = blur_px / float(SAMPLES);
		vec2 step_x = vec2(TEXTURE_PIXEL_SIZE.x * step_px, 0.0);
		vec2 step_y = vec2(0.0, TEXTURE_PIXEL_SIZE.y * step_px);
		float sigma = float(SAMPLES) * 0.45;
		float wsum = 0.0;
		col = vec4(0.0);
		for (int i = -SAMPLES; i <= SAMPLES; i++) {
			float w = gauss(float(i), sigma);
			col += texture(TEXTURE, UV + step_x * float(i)) * w;
			wsum += w;
		}
		for (int i = -SAMPLES; i <= SAMPLES; i++) {
			float w = gauss(float(i), sigma);
			col += texture(TEXTURE, UV + step_y * float(i)) * w;
			wsum += w;
		}
		col = col / wsum;
	}
	COLOR = col;
}