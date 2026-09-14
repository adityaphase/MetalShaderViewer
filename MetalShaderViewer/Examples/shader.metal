// shader.metal
//
// Metal port of example/shader.frag from the OpenGL_CLI project.
// Cosine-palette kaleidoscope (palette function after Inigo Quilez).
//
// Porting notes:
//   * vec2/vec3      -> float2/float3
//   * gl_FragCoord   -> the `fragCoord` argument (already y-flipped by the
//                       viewer's prelude)
//   * `palette` needs no uniforms, so it takes no `Uniforms u`.

float3 palette(float t)
{
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.263, 0.416, 0.557);

    return a + b * cos(6.28318 * (c * t + d));
}

float4 shaderMain(float2 fragCoord, Uniforms u)
{
    float2 uv = (fragCoord.xy * 2.0 - iResolution.xy) / iResolution.y;
    float2 uv0 = uv;
    float3 finalColor = float3(0.0);

    for (float i = 0.0; i < 4.0; i++)
    {
        uv = fract(uv * 1.5) - 0.5;

        float d = length(uv) * exp(-length(uv0));

        float3 col = palette(length(uv0) + i * 0.4 + iTime * 0.4);

        d = sin(d * 8.0 + iTime) / 8.0;
        d = abs(d);

        d = pow(0.010 / d, 1.2);

        finalColor += col * d;
    }

    return float4(finalColor, 1.0);
}
