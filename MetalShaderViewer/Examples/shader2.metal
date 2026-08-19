// shader2.metal
//
// Metal port of example/shader2.frag from the OpenGL_CLI project.
// Raymarched tunnel of repeating rotating box frames.
//
// Porting notes:
//   * vec2/vec3/mat2 -> float2/float3/float2x2
//   * gl_FragCoord   -> the `fragCoord` argument (already y-flipped by the
//                       viewer's prelude)
//   * mat2(c, s, -s, c) is column-major in GLSL, so each pair becomes one
//     float2 column here. `v * M` means row-vector times matrix in both
//     languages, so the `pos.xy *= rot(...)` idiom carries over unchanged.
//   * GLSL `mod` and Metal `fmod` DIFFER for negative operands: mod() follows
//     floor (result takes the divisor's sign), fmod() truncates (result takes
//     the dividend's sign). `mod(pos - 2.0, 4.0)` goes negative here, so the
//     GLSL definition is spelled out below rather than using fmod.
//   * Only functions that read iTime take a trailing `Uniforms u`.

float3 glslMod(float3 x, float y)
{
    return x - y * floor(x / y);
}

// =====================================================
// ROTATION

float2x2 rot(float a)
{
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

// =====================================================
// SDF

float sdBox(float3 p, float3 b)
{
    float3 q = abs(p) - b;
    return length(max(q, float3(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0);
}

// =====================================================
// OBJECTS

float box(float3 pos, float scale)
{
    pos *= scale;

    float base = sdBox(pos, float3(0.4, 0.4, 0.1)) / 1.5;

    pos.xy *= 5.0;
    pos.y -= 3.5;
    pos.xy = pos.xy * rot(0.75);

    return -base;
}

float box_set(float3 pos, Uniforms u)
{
    float3 p0 = pos;

    pos = p0;
    pos.y += sin(iTime * 0.4) * 2.5;
    pos.xy = pos.xy * rot(0.8);
    float box1 = box(pos, 2.0 - abs(sin(iTime * 0.4)) * 1.5);

    pos = p0;
    pos.y -= sin(iTime * 0.4) * 2.5;
    pos.xy = pos.xy * rot(0.8);
    float box2 = box(pos, 2.0 - abs(sin(iTime * 0.4)) * 1.5);

    pos = p0;
    pos.x += sin(iTime * 0.4) * 2.5;
    pos.xy = pos.xy * rot(0.8);
    float box3 = box(pos, 2.0 - abs(sin(iTime * 0.4)) * 1.5);

    pos = p0;
    pos.x -= sin(iTime * 0.4) * 2.5;
    pos.xy = pos.xy * rot(0.8);
    float box4 = box(pos, 2.0 - abs(sin(iTime * 0.4)) * 1.5);

    pos = p0;
    pos.xy = pos.xy * rot(0.8);
    float box5 = box(pos, 0.5) * 6.0;

    pos = p0;
    float box6 = box(pos, 0.5) * 6.0;

    return max(max(max(max(max(box1, box2), box3), box4), box5), box6);
}

float map(float3 pos, Uniforms u)
{
    return box_set(pos, u);
}

// =====================================================
// MAIN

float4 shaderMain(float2 fragCoord, Uniforms u)
{
    float2 p = (fragCoord.xy * 2.0 - iResolution.xy)
             / min(iResolution.x, iResolution.y);

    float3 ro = float3(0.0, -0.2, iTime * 4.0);
    float3 ray = normalize(float3(p, 1.5));

    ray.xy = ray.xy * rot(sin(iTime * 0.03) * 5.0);
    ray.yz = ray.yz * rot(sin(iTime * 0.05) * 0.2);

    float t = 0.1;
    float ac = 0.0;

    for (int i = 0; i < 99; i++)
    {
        float3 pos = ro + ray * t;

        pos = glslMod(pos - 2.0, 4.0) - 2.0;

        float gTime = iTime - float(i) * 0.01;

        float d = map(pos, u);

        d = max(abs(d), 0.01);

        ac += exp(-d * 23.0);

        t += d * 0.55;
    }

    float3 col = float3(ac * 0.02);

    col += float3(
        0.0,
        0.2 * abs(sin(iTime)),
        0.5 + sin(iTime) * 0.2
    );

    float alpha = 1.0 - t * (0.02 + 0.02 * sin(iTime));

    return float4(col, alpha);
}
