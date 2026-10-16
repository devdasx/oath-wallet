#include <metal_stdlib>
using namespace metal;

// Four float2 and five float4 values, mirrored in Swift (112 bytes).
struct AtmosphereUniforms {
    float2 resolution;
    float2 timeAndAppearance;
    float2 interaction;
    float2 logoLayout;
    float4 logoRect;
    float4 fadeLayout;
    float4 copyRect;
    float4 logoClip;
    float4 panelLayout;
};
// Eight float4 values, mirrored by OathSilkColors in Swift.
struct OathSilkColors {
    float4 lightDeep, lightCrest, darkDeep, darkCrest;
    float4 lightReflection, darkReflection, lightRest, darkRest;
};
struct VertexOutput { float4 position [[position]]; float2 uv; };
vertex VertexOutput oathVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y) };
}
float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float3 oathLinearRGB(float3 encoded) {
    return select(pow((encoded + 0.055) / 1.055, float3(2.4)), encoded / 12.92, encoded <= 0.04045);
}

float3 oathEncodedRGB(float3 linear) {
    return select(1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055, linear * 12.92, linear <= 0.0031308);
}

// A single continuous sheet. Broad currents cross the whole upper viewport;
// the moving surface, depth and reflections share one continuous time field.
// Height and its analytic slope share one evaluation. Previously the fragment
// evaluated this entire warped surface five times for finite differences.
// Keep the same material, resolution and motion while freeing GPU time for
// native keyboard, glass and navigation compositing.
float3 silkHeightAndGradient(float2 p, float t) {
    float2 center = float2(0.10 + 0.10 * sin(t * 0.16), 0.09);
    float2 local = p - center;
    float turn = (0.88 + 0.12 * sin(t * 0.13)) * exp(-dot(local, local) * 0.52);
    float c = cos(turn), s = sin(turn);
    float2 turnGradient = -1.04 * turn * local;
    float2 warpedXGradient = float2(c, -s) + (-local.x*s - local.y*c) * turnGradient;
    float2 warpedYGradient = float2(s, c) + (local.x*c - local.y*s) * turnGradient;
    p = float2(local.x*c - local.y*s, local.x*s + local.y*c) + center;
    float spinePhase = p.y * 2.08 + t * 0.25 + 0.70;
    float secondSpinePhase = p.y * 3.35 - t * 0.17 - 0.20;
    float spine = 0.27 * sin(spinePhase) + 0.095 * sin(secondSpinePhase);
    float spineSlope = 0.27 * 2.08 * cos(spinePhase) + 0.095 * 3.35 * cos(secondSpinePhase);
    float baseQ = p.x - spine + p.y * 0.17;
    float scalePhase = p.y * 1.70 - t * 0.11;
    float scale = 1.0 + 0.13 * sin(scalePhase);
    float q = baseQ * scale;
    float2 qGradient = float2(scale, (0.17 - spineSlope) * scale + baseQ * 0.13 * 1.70 * cos(scalePhase));
    float ripplePhase = p.y * 2.10 + t * 0.18;
    float primaryPhase = q * 8.15 + 0.22 * sin(ripplePhase);
    float undertowPhase = q * 13.70 - p.y * 0.82 - t * 0.21;
    float finePhase = q * 22.40 + p.y * 1.28 + t * 0.15;
    float broadPhase = p.y * 1.85 + p.x * 1.70 - t * 0.19;
    float height = sin(primaryPhase) * 0.175 + sin(undertowPhase) * 0.025
                 + sin(finePhase) * 0.0045 + 0.030 * cos(broadPhase);
    float2 gradient = 0.175 * cos(primaryPhase) * (8.15 * qGradient + float2(0, 0.22 * 2.10 * cos(ripplePhase)))
                    + 0.025 * cos(undertowPhase) * (13.70 * qGradient + float2(0, -0.82))
                    + 0.0045 * cos(finePhase) * (22.40 * qGradient + float2(0, 1.28))
                    - 0.030 * sin(broadPhase) * float2(1.70, 1.85);
    gradient = gradient.x * warpedXGradient + gradient.y * warpedYGradient;
    return float3(height, gradient);
}

float3 silkColor(float2 uv, constant AtmosphereUniforms &u, constant OathSilkColors &palette) {
    float t = u.timeAndAppearance.x;
    float dark = u.timeAndAppearance.y;
    float aspect = u.resolution.y / max(u.resolution.x, 1.0);
    float2 p = (uv - float2(0.47, 0.32)) * float2(1.18, aspect * 1.18);
    p -= u.interaction * float2(0.085, 0.065);
    float angle = 0.31 + 0.035 * sin(t * 0.09);
    float c = cos(angle), s = sin(angle);
    p = float2(p.x*c + p.y*s, p.y*c - p.x*s);
    p.x += 0.047 * sin(t * 0.15);
    p.y += 0.031 * cos(t * 0.13);
    float3 surface = silkHeightAndGradient(p, t);
    float h = surface.x, dx = surface.y, dy = surface.z;
    float3 n = normalize(float3(-dx, -dy, 0.86));
    float3 eye = normalize(float3(p * float2(-0.13, -0.09), 1.0));
    float3 reflection = reflect(-eye, n);
    float diffuse = max(dot(n, normalize(float3(-0.56, -0.42, 1.0))), 0.0);
    float depth = smoothstep(-0.20, 0.19, h);
    float occlusion = mix(0.37, 1.0, smoothstep(-0.19, 0.12, h));
    float facing = clamp(dot(n, eye), 0.0, 1.0);

    float3 albedo = mix(mix(palette.lightDeep.rgb, palette.lightCrest.rgb, depth),
                        mix(palette.darkDeep.rgb, palette.darkCrest.rgb, depth), dark);
    float3 color = albedo * mix(0.69 + diffuse * 0.31, 0.30 + diffuse * 0.70, dark)
                  * mix(0.91, occlusion, dark);

    // Broad reflected light and a narrow grazing reflection reveal the volume.
    // They move independently of the surface, like light through folded glass.
    float boxAxis = reflection.x + reflection.y * 0.12 + 0.36 + 0.07 * sin(t * 0.11);
    float box = exp(-pow(boxAxis / 0.34, 2.0))
              * (0.78 + 0.22 * cos(reflection.y * 1.65 - t * 0.08));
    float stripAxis = reflection.x - reflection.y * 0.08 - 0.59 + 0.035 * cos(t * 0.14);
    float strip = exp(-pow(stripAxis / 0.037, 2.0));
    float rim = pow(1.0 - facing, 2.5);
    float3 reflectionColor = mix(palette.lightReflection.rgb, palette.darkReflection.rgb, dark);
    color += box * reflectionColor * (0.57 + depth * 0.43);
    color += strip * mix(palette.lightCrest.rgb, palette.darkReflection.rgb, dark) * 0.20;
    color += rim * palette.darkReflection.rgb * 0.25;
    float pearlGlint = pow(max(dot(n, normalize(float3(-0.40, -0.25, 1.0))), 0.0), 44.0);
    color += pearlGlint * reflectionColor * mix(0.20, 0.16, dark);
    color += facing * facing * reflectionColor * mix(0.15, 0.025, dark);

    // Surface neutrals belong to the page, never to the colored material.
    // Reflections provide highlights without mixing a white veil into the accent.
    float vignette = 1.0 - 0.09 * dot(uv - float2(0.5, 0.28), uv - float2(0.5, 0.28));
    color *= vignette;
    float3 restingColor = mix(palette.lightRest.rgb, palette.darkRest.rgb, dark);
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
        float2 center = u.copyRect.xy + u.copyRect.zw * 0.5;
        float2 outside = max(abs(uv - center) - u.copyRect.zw * 0.5, 0.0);
        float reading = 1.0 - smoothstep(0.0, 0.065, length(outside));
        float3 linear = oathLinearRGB(clamp(color, 0.0, 1.0));
        float luminance = dot(linear, float3(0.2126, 0.7152, 0.0722));
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

// Shared with the offline startup-asset renderer.
float3 oathLogoGlass(float4 atlas, float time) {
    // Undo coverage weighting after filtering; empty pixels never tilt
    // the normal or produce false highlights along the silhouette.
    float3 encodedNormal = atlas.rgb / max(atlas.a, 0.0001);
    // Blender camera space looks down -Z; Metal lighting faces +Z.
    float3 normal = normalize(float3(encodedNormal.rg * 2.0 - 1.0, 1.0 - encodedNormal.b * 2.0));
    float face = clamp(normal.z, 0.0, 1.0);
    float rim = pow(1.0 - face, 2.0);
    // Opaque body: no background sampling or transmission through the mark.
    // Atlas alpha controls silhouette coverage and edge antialiasing only.
    float3 glass = float3(0.955, 0.970, 0.990) * (0.94 + 0.04 * face);
    float3 key = normalize(float3(-0.48 + 0.035*sin(time*0.19), 0.65, 1.0));
    float3 fill = normalize(float3(0.75, -0.50, 0.65));
    float highlight = pow(max(dot(normal,key),0.0), 26.0);
    float ribbon = pow(max(dot(normal,fill),0.0), 34.0);
    float edgeShade = max(dot(normal,normalize(float3(0.65,-0.75,0.0))),0.0) * (1.0-face);
    glass *= 1.0 - edgeShade * 0.43;
    glass = mix(glass, float3(0.96,0.985,1.0), rim * 0.74);
    glass += (highlight * 0.42 + ribbon * 0.25) * float3(0.96,0.985,1.0);
    return clamp(glass, 0.0, 1.0);
}

// The normal atlas is rendered from the supplied Blender contours and bevels.
// The body is opaque white; only its reflective lighting changes in real time.
fragment float4 oathFragment(VertexOutput in [[stage_in]],
                             constant AtmosphereUniforms &u [[buffer(0)]],
                             constant OathSilkColors &palette [[buffer(1)]],
                             texture2d<float> logoNormals [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 uv = in.uv;
    float dark = u.timeAndAppearance.y;
    float time = u.timeAndAppearance.x;
    float3 color = silkColor(uv, u, palette);
    float centerY = u.logoLayout.x > 0.0 ? u.logoLayout.x : 0.214;
    float width = u.logoLayout.y > 0.0 ? u.logoLayout.y : 0.66;
    float2 logoSize = float2(width, width * 0.75 * u.resolution.x / max(u.resolution.y, 1.0));
    float2 logoCenter = float2(0.5, centerY);
    if (u.logoRect.z > 0.0) {
        logoSize = u.logoRect.zw;
        logoCenter = u.logoRect.xy + logoSize * 0.5;
    }
    float2 logoUV = (uv - logoCenter) / logoSize + 0.5;
    // Derivatives must be calculated before the bounds branch. Implicit LOD
    // inside a divergent branch can sample coarse mips along the texture border.
    gradient2d logoGradient(dfdx(logoUV), dfdy(logoUV));
    bool insideClip = u.logoClip.z <= 0.0 ||
        (all(uv >= u.logoClip.xy) && all(uv <= u.logoClip.xy + u.logoClip.zw));
    if (insideClip && all(logoUV >= 0.0) && all(logoUV <= 1.0)) {
        float4 atlas = logoNormals.sample(linearSampler, logoUV, logoGradient);
        float shadow = logoNormals.sample(linearSampler, logoUV - float2(0.008, 0.026), logoGradient).a * 0.5
                     + logoNormals.sample(linearSampler, logoUV - float2(-0.006, 0.018), logoGradient).a * 0.3
                     + logoNormals.sample(linearSampler, logoUV - float2(0.016, 0.016), logoGradient).a * 0.2;
        color *= 1.0 - shadow * (1.0 - atlas.a) * mix(0.13, 0.23, dark);
        if (atlas.a > 0.001) {
            color = mix(color, oathLogoGlass(atlas, time), atlas.a);
        }
    }
    // The action pane is a uniform, full-height surface. Return before dithering
    // so light mode is exactly white, without animated reflections or grain.
    bool actionPanel = u.panelLayout.y > 0.0 ? uv.x >= u.panelLayout.x : uv.x < u.panelLayout.x;
    if (u.panelLayout.y != 0.0 && actionPanel) {
        return float4(mix(float3(1.0), palette.darkRest.rgb, dark), 1.0);
    }
    color += (hash21(uv * u.resolution) - 0.5) * 0.002;
    return float4(clamp(color,0.0,1.0),1.0);
}

// One-time import pass. Mipmaps average coverage-weighted normals and coverage
// together; the fragment shader restores the normal after texture filtering.
kernel void oathPrepareLogoNormals(texture2d<float, access::read> source [[texture(0)]],
                                   texture2d<float, access::write> destination [[texture(1)]],
                                   uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= source.get_width() || pixel.y >= source.get_height()) { return; }
    float4 atlas = source.read(pixel);
    destination.write(float4(atlas.rgb * atlas.a, atlas.a), pixel);
}
