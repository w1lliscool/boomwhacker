shader_type canvas_item;

uniform sampler2D sheet_texture : filter_linear, repeat_disable;
uniform float scroll_x = 0.0;
uniform float strip_w = 1.0;
uniform float strip_h = 1.0;

void fragment() {
	vec2 uv = UV;
	float visible_w = 1920.0 / strip_w;
	uv.x = scroll_x + uv.x * visible_w;
	COLOR = texture(sheet_texture, uv);
	if (COLOR.a < 0.01) discard;
}
