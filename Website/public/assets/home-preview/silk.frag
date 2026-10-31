// WebGL port of Shaders/OathSilk.metal: same analytic folds and light-appearance material.
precision highp float;
uniform vec2 resolution;
uniform float time;
uniform vec3 deep, crest, reflectionColor, darkReflection;
struct AtmosphereUniforms { vec2 resolution; vec2 timeAndAppearance; vec2 interaction; vec4 fadeLayout; vec4 copyRect; vec4 panelLayout; };
struct OathSilkColors { vec4 lightDeep; vec4 lightCrest; vec4 darkDeep; vec4 darkCrest; vec4 lightReflection; vec4 darkReflection; vec4 lightRest; vec4 darkRest; };
vec3 oathLinearRGB(vec3 x) { return mix(x / 12.92, pow((x + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), x)); }
vec3 oathEncodedRGB(vec3 x) { return mix(x * 12.92, 1.055 * pow(x, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), x)); }
vec3 silkHeightAndGradient(vec2 p, float t) {
    vec2 center = vec2(0.10 + 0.10 * sin(t * 0.16), 0.09);
    vec2 local = p - center;
    float turn = (0.88 + 0.12 * sin(t * 0.13)) * exp(-dot(local, local) * 0.52);
    float c = cos(turn), s = sin(turn);
    vec2 turnGradient = -1.04 * turn * local;
    vec2 warpedXGradient = vec2(c, -s) + (-local.x*s - local.y*c) * turnGradient;
    vec2 warpedYGradient = vec2(s, c) + (local.x*c - local.y*s) * turnGradient;
    p = vec2(local.x*c - local.y*s, local.x*s + local.y*c) + center;
    float spinePhase = p.y * 2.08 + t * 0.25 + 0.70;
    float secondSpinePhase = p.y * 3.35 - t * 0.17 - 0.20;
    float spine = 0.27 * sin(spinePhase) + 0.095 * sin(secondSpinePhase);
    float spineSlope = 0.27 * 2.08 * cos(spinePhase) + 0.095 * 3.35 * cos(secondSpinePhase);
    float baseQ = p.x - spine + p.y * 0.17;
    float scalePhase = p.y * 1.70 - t * 0.11;
    float scale = 1.0 + 0.13 * sin(scalePhase);
    float q = baseQ * scale;
    vec2 qGradient = vec2(scale, (0.17 - spineSlope) * scale + baseQ * 0.13 * 1.70 * cos(scalePhase));
    float ripplePhase = p.y * 2.10 + t * 0.18;
    float primaryPhase = q * 8.15 + 0.22 * sin(ripplePhase);
    float undertowPhase = q * 13.70 - p.y * 0.82 - t * 0.21;
    float finePhase = q * 22.40 + p.y * 1.28 + t * 0.15;
    float broadPhase = p.y * 1.85 + p.x * 1.70 - t * 0.19;
    float height = sin(primaryPhase) * 0.175 + sin(undertowPhase) * 0.025
                 + sin(finePhase) * 0.0045 + 0.030 * cos(broadPhase);
    vec2 gradient = 0.175 * cos(primaryPhase) * (8.15 * qGradient + vec2(0, 0.22 * 2.10 * cos(ripplePhase)))
                    + 0.025 * cos(undertowPhase) * (13.70 * qGradient + vec2(0, -0.82))
                    + 0.0045 * cos(finePhase) * (22.40 * qGradient + vec2(0, 1.28))
                    - 0.030 * sin(broadPhase) * vec2(1.70, 1.85);
    gradient = gradient.x * warpedXGradient + gradient.y * warpedYGradient;
    return vec3(height, gradient);
}

vec3 silkColor(vec2 uv, AtmosphereUniforms u, OathSilkColors palette) {
    float t = u.timeAndAppearance.x;
    float dark = u.timeAndAppearance.y;
    float aspect = u.resolution.y / max(u.resolution.x, 1.0);
    vec2 p = (uv - vec2(0.47, 0.32)) * vec2(1.18, aspect * 1.18);
    p -= u.interaction * vec2(0.085, 0.065);
    float angle = 0.31 + 0.035 * sin(t * 0.09);
    float c = cos(angle), s = sin(angle);
    p = vec2(p.x*c + p.y*s, p.y*c - p.x*s);
    p.x += 0.047 * sin(t * 0.15);
    p.y += 0.031 * cos(t * 0.13);
    vec3 surface = silkHeightAndGradient(p, t);
    float h = surface.x, dx = surface.y, dy = surface.z;
    vec3 n = normalize(vec3(-dx, -dy, 0.86));
    vec3 eye = normalize(vec3(p * vec2(-0.13, -0.09), 1.0));
    vec3 reflection = reflect(-eye, n);
    float diffuse = max(dot(n, normalize(vec3(-0.56, -0.42, 1.0))), 0.0);
    float depth = smoothstep(-0.20, 0.19, h);
    float occlusion = mix(0.37, 1.0, smoothstep(-0.19, 0.12, h));
    float facing = clamp(dot(n, eye), 0.0, 1.0);

    vec3 albedo = mix(mix(palette.lightDeep.rgb, palette.lightCrest.rgb, depth),
                        mix(palette.darkDeep.rgb, palette.darkCrest.rgb, depth), dark);
    vec3 color = albedo * mix(0.69 + diffuse * 0.31, 0.30 + diffuse * 0.70, dark)
                  * mix(0.91, occlusion, dark);

    // Broad reflected light and a narrow grazing reflection reveal the volume.
    // They move independently of the surface, like light through folded glass.
    float boxAxis = reflection.x + reflection.y * 0.12 + 0.36 + 0.07 * sin(t * 0.11);
    float box = exp(-(boxAxis / 0.34) * (boxAxis / 0.34))
              * (0.78 + 0.22 * cos(reflection.y * 1.65 - t * 0.08));
    float stripAxis = reflection.x - reflection.y * 0.08 - 0.59 + 0.035 * cos(t * 0.14);
    float strip = exp(-(stripAxis / 0.037) * (stripAxis / 0.037));
    float rim = pow(1.0 - facing, 2.5);
    vec3 reflectionColor = mix(palette.lightReflection.rgb, palette.darkReflection.rgb, dark);
    color += box * reflectionColor * (0.57 + depth * 0.43);
    color += strip * mix(palette.lightCrest.rgb, palette.darkReflection.rgb, dark) * 0.20;
    color += rim * palette.darkReflection.rgb * 0.25;
    float pearlGlint = pow(max(dot(n, normalize(vec3(-0.40, -0.25, 1.0))), 0.0), 44.0);
    color += pearlGlint * reflectionColor * mix(0.20, 0.16, dark);
    color += facing * facing * reflectionColor * mix(0.15, 0.025, dark);

    // Surface neutrals belong to the page, never to the colored material.
    // Reflections provide highlights without mixing a white veil into the accent.
    float vignette = 1.0 - 0.09 * dot(uv - vec2(0.5, 0.28), uv - vec2(0.5, 0.28));
    color *= vignette;
    vec3 restingColor = mix(palette.lightRest.rgb, palette.darkRest.rgb, dark);
    // Keep the entire top half immersed in color before dissolving into space
    // for onboarding content. No object silhouette or isolated center vignette.
    float dissolveY = uv.y + 0.012 * sin(uv.x * 4.8 + 0.8 + 0.2 * sin(t * 0.08));
    float fadeStart = 0.46, fadeEnd = 0.72;
    if (u.fadeLayout.y > 0.0) {
        float across = smoothstep(0.30, 0.70, uv.x);
        fadeStart = mix(u.fadeLayout.x, u.fadeLayout.z, across);
        fadeEnd = mix(u.fadeLayout.y, u.fadeLayout.w, across);
    }
    // A soft reading zone keeps the explicitly white typography legible in
    // both appearances while retaining the animated folds and the chosen hue.
    if (u.copyRect.z > 0.0) {
        vec2 center = u.copyRect.xy + u.copyRect.zw * 0.5;
        vec2 outside = max(abs(uv - center) - u.copyRect.zw * 0.5, vec2(0.0));
        float reading = 1.0 - smoothstep(0.0, 0.065, length(outside));
        vec3 linear = oathLinearRGB(clamp(color, 0.0, 1.0));
        float luminance = dot(linear, vec3(0.2126, 0.7152, 0.0722));
        float shade = min(1.0, 0.10 / max(luminance, 0.001));
        color = oathEncodedRGB(linear * mix(1.0, shade, reading));
    }
    // Wide layouts retain animation to the bottom edge of the introduction.
    // Only stacked layouts dissolve vertically into their action area.
    if (u.panelLayout.y == 0.0) {
        color = mix(color, restingColor, smoothstep(fadeStart, fadeEnd, dissolveY));
    }
    return clamp(color, 0.0, 1.0);
}


float hash21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
void main() {
  vec2 uv = vec2(gl_FragCoord.x, resolution.y - gl_FragCoord.y) / resolution;
  // The 440 x 460 header uses the app's walletBackdrop placement and full reading zone.
  AtmosphereUniforms u = AtmosphereUniforms(resolution, vec2(time, 0.0), vec2(0.0), vec4(420.0/460.0,604.0/460.0,420.0/460.0,604.0/460.0), vec4(0.0,0.0,1.0,1.0), vec4(0.0));
  OathSilkColors palette = OathSilkColors(vec4(deep,1.0),vec4(crest,1.0),vec4(deep,1.0),vec4(crest,1.0),vec4(reflectionColor,1.0),vec4(darkReflection,1.0),vec4(1.0),vec4(0.086,0.086,0.086,1.0));
  vec3 color = silkColor(uv, u, palette) + (hash21(uv * resolution) - 0.5) * 0.002;
  gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
