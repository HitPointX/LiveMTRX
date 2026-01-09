// Conceptual CRT fragment shader (GLSL-style pseudocode)
// When porting to Metal, rewrite to .metal and use appropriate types.

uniform sampler2D glyphAtlas;
uniform sampler2D bloomTex;

in vec2 v_uv;
out vec4 out_color;

void main() {
    vec3 col = texture(glyphAtlas, v_uv).rgb;
    float intensity = 1.0; // provided per-instance
    col *= intensity;

    // add bloom
    col += texture(bloomTex, v_uv).rgb * 0.6;

    // RGB subpixel mask (triads)
    float m = mod(floor(gl_FragCoord.x), 3.0);
    vec3 mask = (m == 0.0) ? vec3(1.0,0.7,0.7) : (m == 1.0) ? vec3(0.7,1.0,0.7) : vec3(0.7,0.7,1.0);
    col *= mask;

    // scanline
    col *= 0.9 + 0.1 * sin(gl_FragCoord.y * 3.14159);

    // chroma offsets (conceptual)
    // col.r = texture(glyphAtlas, v_uv + vec2(0.001,0)).r;
    // col.b = texture(glyphAtlas, v_uv - vec2(0.001,0)).b;

    // barrel distortion and vignette would be applied here in UV space

    out_color = vec4(col, 1.0);
}
