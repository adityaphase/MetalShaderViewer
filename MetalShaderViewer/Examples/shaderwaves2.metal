// shaderwaves2.metal
//
// Metal port of example/shaderwaves2.frag from the OpenGL_CLI project.
// Original GLSL: afl_ext 2017-2024, MIT License.
//
// Move the mouse over the output window to swing the camera around.
//
// Porting notes vs. the GLSL original:
//   * vec2/vec3/mat3          -> float2/float3/float3x3
//   * gl_FragCoord            -> the `fragCoord` argument (already y-flipped by
//                                the viewer's prelude)
//   * uniforms                -> Metal has no mutable globals, so every helper
//                                that reads iTime/iResolution/iMouse takes a
//                                trailing `Uniforms u` and the iXxx macros
//                                resolve against it
//   * mat3(a,b,c, d,e,f, g,h,i) is column-major in GLSL, so each group of three
//     becomes one float3 column here.

#define DRAG_MULT 0.38
#define WATER_DEPTH 1.0
#define CAMERA_HEIGHT 1.5
#define ITERATIONS_RAYMARCH 12
#define ITERATIONS_NORMAL 36

#define NormalizedMouse (iMouse.xy / iResolution.xy)

// ------------------------------------------------------------

float2 wavedx(float2 position, float2 direction, float frequency, float timeshift)
{
    float x = dot(direction, position) * frequency + timeshift;
    float wave = exp(sin(x) - 1.0);
    float dx = wave * cos(x);
    return float2(wave, -dx);
}

float getwaves(float2 position, int iterations, Uniforms u)
{
    float wavePhaseShift = length(position) * 0.1;
    float iter = 0.0;
    float frequency = 1.0;
    float timeMultiplier = 2.0;
    float weight = 1.0;
    float sumOfValues = 0.0;
    float sumOfWeights = 0.0;

    for (int i = 0; i < iterations; i++)
    {
        float2 p = float2(sin(iter), cos(iter));

        float2 res = wavedx(position, p, frequency,
                            iTime * timeMultiplier + wavePhaseShift);

        position += p * res.y * weight * DRAG_MULT;

        sumOfValues += res.x * weight;
        sumOfWeights += weight;

        weight = mix(weight, 0.0, 0.2);
        frequency *= 1.18;
        timeMultiplier *= 1.07;

        iter += 1232.399963;
    }

    return sumOfValues / sumOfWeights;
}

// ------------------------------------------------------------

float raymarchwater(float3 camera, float3 start, float3 end, float depth, Uniforms u)
{
    float3 pos = start;
    float3 dir = normalize(end - start);

    for (int i = 0; i < 64; i++)
    {
        float height = getwaves(pos.xz, ITERATIONS_RAYMARCH, u) * depth - depth;

        if (height + 0.01 > pos.y)
        {
            return distance(pos, camera);
        }

        pos += dir * (pos.y - height);
    }

    return distance(start, camera);
}

// ------------------------------------------------------------

float3 waterNormal(float2 pos, float e, float depth, Uniforms u)
{
    float2 ex = float2(e, 0.0);

    float H = getwaves(pos.xy, ITERATIONS_NORMAL, u) * depth;

    float3 a = float3(pos.x, H, pos.y);

    return normalize(cross(
        a - float3(pos.x - e,
                   getwaves(pos.xy - ex.xy, ITERATIONS_NORMAL, u) * depth,
                   pos.y),
        a - float3(pos.x,
                   getwaves(pos.xy + ex.yx, ITERATIONS_NORMAL, u) * depth,
                   pos.y + e)));
}

// ------------------------------------------------------------

float3x3 createRotationMatrixAxisAngle(float3 axis, float angle)
{
    float s = sin(angle);
    float c = cos(angle);
    float oc = 1.0 - c;

    return float3x3(
        float3(oc * axis.x * axis.x + c,
               oc * axis.x * axis.y - axis.z * s,
               oc * axis.z * axis.x + axis.y * s),
        float3(oc * axis.x * axis.y + axis.z * s,
               oc * axis.y * axis.y + c,
               oc * axis.y * axis.z - axis.x * s),
        float3(oc * axis.z * axis.x - axis.y * s,
               oc * axis.y * axis.z + axis.x * s,
               oc * axis.z * axis.z + c));
}

// ------------------------------------------------------------

float3 getRay(float2 fragCoord, Uniforms u)
{
    float2 uv = ((fragCoord.xy / iResolution.xy) * 2.0 - 1.0)
              * float2(iResolution.x / iResolution.y, 1.0);

    float3 proj = normalize(float3(uv.x, uv.y, 1.5));

    if (iResolution.x < 600.0)
    {
        return proj;
    }

    return createRotationMatrixAxisAngle(
               float3(0.0, -1.0, 0.0),
               3.0 * ((NormalizedMouse.x + 0.5) * 2.0 - 1.0))
         * createRotationMatrixAxisAngle(
               float3(1.0, 0.0, 0.0),
               0.5 + 1.5 * ((NormalizedMouse.y == 0.0 ? 0.27 : NormalizedMouse.y) * 2.0 - 1.0))
         * proj;
}

// ------------------------------------------------------------

float intersectPlane(float3 origin, float3 direction, float3 point3, float3 normalVec)
{
    float d = dot(direction, normalVec);
    d = abs(d) < 0.0001 ? 0.0001 : d;
    return clamp(dot(point3 - origin, normalVec) / d, -1.0, 9991999.0);
}

// ------------------------------------------------------------

float3 extra_cheap_atmosphere(float3 raydir, float3 sundir)
{
    float special_trick = 1.0 / (raydir.y + 0.1);
    float special_trick2 = 1.0 / (sundir.y * 11.0 + 1.0);

    float raysundt = pow(abs(dot(sundir, raydir)), 2.0);
    float sundt = pow(max(0.0, dot(sundir, raydir)), 8.0);

    float mymie = sundt * special_trick * 0.2;

    float3 suncolor = mix(float3(1.0),
                          max(float3(0.0),
                              float3(1.0) - float3(5.5, 13.0, 22.4) / 22.4),
                          special_trick2);

    float3 bluesky = float3(5.5, 13.0, 22.4) / 22.4 * suncolor;

    float3 bluesky2 = max(float3(0.0),
                          bluesky - float3(5.5, 13.0, 22.4) * 0.002
                          * (special_trick + -6.0 * sundir.y * sundir.y));

    bluesky2 *= special_trick * (0.24 + raysundt * 0.24);

    return bluesky2 * (1.0 + pow(1.0 - raydir.y, 3.0));
}

// ------------------------------------------------------------

float3 getSunDirection(Uniforms u)
{
    return normalize(float3(-0.0773502691896258,
                            0.5 + sin(iTime * 0.2 + 2.6) * 0.45,
                            0.5773502691896258));
}

float3 getAtmosphere(float3 dir, Uniforms u)
{
    return extra_cheap_atmosphere(dir, getSunDirection(u)) * 0.5;
}

float getSun(float3 dir, Uniforms u)
{
    return pow(max(0.0, dot(dir, getSunDirection(u))), 720.0) * 210.0;
}

// ------------------------------------------------------------

float3 aces_tonemap(float3 color)
{
    float3x3 m1 = float3x3(
        float3(0.59719, 0.07600, 0.02840),
        float3(0.35458, 0.90834, 0.13383),
        float3(0.04823, 0.01566, 0.83777));

    float3x3 m2 = float3x3(
        float3( 1.60475, -0.10208, -0.00327),
        float3(-0.53108,  1.10813, -0.07276),
        float3(-0.07367, -0.00605,  1.07602));

    float3 v = m1 * color;

    float3 a = v * (v + 0.0245786) - 0.000090537;
    float3 b = v * (0.983729 * v + 0.4329510) + 0.238081;

    return pow(clamp(m2 * (a / b), float3(0.0), float3(1.0)), float3(1.0 / 2.2));
}

// ------------------------------------------------------------

float4 shaderMain(float2 fragCoord, Uniforms u)
{
    float3 ray = getRay(fragCoord, u);

    if (ray.y >= 0.0)
    {
        float3 C = getAtmosphere(ray, u) + getSun(ray, u);
        return float4(aces_tonemap(C * 2.0), 1.0);
    }

    float3 waterPlaneHigh = float3(0.0);
    float3 waterPlaneLow  = float3(0.0, -WATER_DEPTH, 0.0);

    float3 origin = float3(iTime * 0.2, CAMERA_HEIGHT, 1.0);

    float highPlaneHit = intersectPlane(origin, ray, waterPlaneHigh, float3(0.0, 1.0, 0.0));
    float lowPlaneHit  = intersectPlane(origin, ray, waterPlaneLow,  float3(0.0, 1.0, 0.0));

    float3 highHitPos = origin + ray * highPlaneHit;
    float3 lowHitPos  = origin + ray * lowPlaneHit;

    float dist = raymarchwater(origin, highHitPos, lowHitPos, WATER_DEPTH, u);

    float3 waterHitPos = origin + ray * dist;

    float3 N = waterNormal(waterHitPos.xz, 0.01, WATER_DEPTH, u);

    N = mix(N, float3(0.0, 1.0, 0.0), 0.8 * min(1.0, sqrt(dist * 0.01) * 1.1));

    float fresnel = 0.04 + (1.0 - 0.04) * pow(1.0 - max(0.0, dot(-N, ray)), 5.0);

    float3 R = normalize(reflect(ray, N));
    R.y = abs(R.y);

    float3 reflection = getAtmosphere(R, u) + getSun(R, u);

    float3 scattering = float3(0.0293, 0.0698, 0.1717) * 0.1
                      * (0.2 + (waterHitPos.y + WATER_DEPTH) / WATER_DEPTH);

    float3 C = fresnel * reflection + scattering;

    return float4(aces_tonemap(C * 2.0), 1.0);
}
