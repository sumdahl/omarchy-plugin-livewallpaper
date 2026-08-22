#version 440

// Comic-print treatment for the live wallpaper. One pass over the already
// composed scene (wallpaper + parallax + glints + motes) so the halftone and
// grain sit on top of everything rather than only the still image, which is
// what makes the frame read as one printed cel instead of layered sprites.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;        // seconds, wrapped by the host to stay float-precise
    float pulse;       // 0..1 spider-sense envelope
    float aberration;  // max channel split, in UV at pulse == 1
    float halftone;    // ben-day dot strength
    float dotScale;    // dots across the short edge
    float grain;       // film grain strength
    float vignette;    // edge darkening
    float bloom;       // highlight lift
    vec2 resolution;   // pixels
    vec4 accent;       // theme accent, drives the dots and the pulse rim
    vec4 secondary;    // theme secondary, drives the opposite dot screen
};

layout(binding = 1) uniform sampler2D source;

float hash(vec2 p) {
    p = fract(p * vec2(443.8975, 397.2973));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

// Rotated dot screen. Real ben-day plates are rotated per ink to avoid moire;
// the same trick keeps the two colour screens from beating against each other.
float dotScreen(vec2 uv, float angle, float scale, float aspect) {
    float s = sin(angle);
    float c = cos(angle);
    vec2 p = vec2(uv.x * aspect, uv.y) * scale;
    p = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
    vec2 cell = fract(p) - 0.5;
    return length(cell);
}

void main() {
    vec2 uv = qt_TexCoord0;
    float aspect = resolution.x / max(resolution.y, 1.0);

    // Radial chromatic split. Zero at the optical centre so the subject stays
    // sharp and only the frame edges misregister, the way a bad print does.
    vec2 centred = uv - 0.5;
    float radius = length(centred * vec2(aspect, 1.0));
    float split = aberration * pulse * radius;
    vec2 dir = radius > 0.0001 ? centred / radius : vec2(0.0);

    vec4 texR = texture(source, uv + dir * split);
    vec4 texG = texture(source, uv);
    vec4 texB = texture(source, uv - dir * split);
    vec3 col = vec3(texR.r, texG.g, texB.b);
    float alpha = texG.a;

    float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));

    // Ben-day screens. Weighted to the midtones rather than to everything
    // dark: a printer lays ink where there is tone to describe, so deep
    // shadows stay clean and a large flat sky does not turn into a screen
    // door. A small floor keeps some tooth in the blacks.
    if (halftone > 0.0005) {
        float scale = dotScale;
        float mid = smoothstep(0.02, 0.20, luma) * (1.0 - smoothstep(0.45, 0.92, luma));
        float weight = 0.16 + 0.84 * mid;

        float dA = dotScreen(uv, 0.2618, scale, aspect);          // 15 deg
        float rA = 0.34 * weight;
        float inkA = 1.0 - smoothstep(rA - 0.06, rA + 0.06, dA);

        float dB = dotScreen(uv, 1.3090, scale * 1.31, aspect);   // 75 deg
        float rB = 0.30 * weight;
        float inkB = 1.0 - smoothstep(rB - 0.06, rB + 0.06, dB);

        vec3 ink = accent.rgb * inkA + secondary.rgb * inkB * 0.7;
        col = col + ink * halftone * weight;
    }

    // Spider-sense rim: accent light crawling in from the corners at the peak
    // of the pulse, never on the centre of the frame.
    float rim = smoothstep(0.30, 0.78, radius);
    col += accent.rgb * rim * pulse * 0.28;

    // Highlight lift, so neon signs and suit piping keep glowing under the ink.
    if (bloom > 0.0005) {
        float hot = smoothstep(0.62, 1.0, luma);
        col += col * hot * bloom;
    }

    // Animated grain. Two offset samples per frame keeps it from crawling in a
    // visible direction, which single-sample grain always does.
    if (grain > 0.0005) {
        vec2 gp = uv * resolution;
        float n = hash(gp + vec2(time * 61.7, time * 43.3));
        float n2 = hash(gp.yx - vec2(time * 37.1, time * 71.9));
        col += (n * 0.6 + n2 * 0.4 - 0.5) * grain;
    }

    // Vignette last so it darkens the ink and the grain together.
    float vig = 1.0 - vignette * smoothstep(0.28, 0.92, radius);
    col *= vig;

    fragColor = vec4(clamp(col, 0.0, 1.0), alpha) * qt_Opacity;
}
