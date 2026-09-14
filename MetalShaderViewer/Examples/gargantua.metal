// gargantua.metal
//
// Physically-based render of a Schwarzschild black hole with a Novikov-Thorne
// style thin accretion disk, in the framing of Interstellar's Gargantua.
//
// Everything on screen is integrated, not faked:
//
//   * Null geodesics are integrated in the Schwarzschild metric with RK4 on the
//     exact orbit equation  u'' + u = 3 M u^2  (u = 1/r), in each ray's own
//     orbital plane. That gives real gravitational lensing, the r = 3M photon
//     ring, the b = 3*sqrt(3)*M shadow edge, and the Einstein ring of the disk
//     wrapped over and under the hole.
//   * The disk is sampled at the exact analytic crossings of the equatorial
//     plane, so a single ray picks up the near face, the far face lensed over
//     the top, and the far face lensed under the bottom, in the correct
//     front-to-back order.
//   * Emitters ride circular Keplerian orbits (v = 0.5c at the ISCO). The full
//     redshift factor  g = sqrt(1-rs/r) / (gamma (1 - beta.n))  combines
//     gravitational redshift with special-relativistic Doppler + beaming.
//   * A redshifted blackbody is exactly a blackbody at T' = g T, so the disk
//     colour is Planckian at the shifted temperature and the brightness scales
//     as g^4 (Liouville: I/nu^3 invariant). The temperature profile is
//     Shakura-Sunyaev / Novikov-Thorne:  T ~ r^-3/4 (1 - sqrt(r_isco/r))^1/4.
//   * Starlight is blueshifted into the static camera by 1/sqrt(1-rs/r_cam) and
//     lensed by the same geodesics.
//
// Units: G = c = M = 1, so rs = 2, photon sphere r = 3, ISCO r = 6.
//
// Note on fidelity to the film: Nolan had the Doppler beaming *removed* from
// the movie's disk because the one-sided brightness confused test audiences.
// This shader keeps it (DOPPLER_BEAMING below turns it off if you want the
// film's symmetric disk).

// ============================================================ tunables

#define MAX_STEPS        320     // geodesic integration budget per ray
#define AA               1       // 1 = off, 2 = 2x2 supersample (4x cost)

#define DOPPLER_BEAMING  1       // 0 -> film-accurate symmetric disk
#define SPIN_DIR         1.0     // +1 prograde (left side approaching)

#define R_IN             6.0     // ISCO
#define R_OUT            22.0
#define T_PEAK           6200.0  // peak emitted blackbody temperature, Kelvin
#define DISK_BRIGHT      1.0
#define TAU0             0.85    // vertical optical depth of the disk at normal incidence
#define TIME_SCALE       9.0     // speeds up the (correct, differential) rotation

#define CAM_R            36.0
#define CAM_INCL         0.122   // ~7 degrees above the disk, Interstellar framing
#define FOV              0.62    // vertical field of view, radians

#define RS               2.0
#define EXPOSURE         0.22

// ============================================================ small utilities

static inline float2x2 rot2(float a)
{
    float c = cos(a), s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

static float hash11(float p)
{
    p = fract(p * 0.1031);
    p *= p + 33.33;
    return fract(p * (p + p));
}

static float hash12(float2 p)
{
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float3 hash33(float3 p)
{
    p = float3(dot(p, float3(127.1, 311.7, 74.7)),
               dot(p, float3(269.5, 183.3, 246.1)),
               dot(p, float3(113.5, 271.9, 124.6)));
    return fract(sin(p) * 43758.5453);
}

static float vnoise2(float2 p)
{
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm2(float2 p)
{
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 5; ++i) {
        s += a * vnoise2(p);
        p = rot2(0.7) * p * 2.02;
        a *= 0.5;
    }
    return s;
}

// ============================================================ blackbody colour
//
// Planckian locus -> CIE xy (Kim et al. cubic fit), xyY -> XYZ -> linear sRGB.
// Returned with unit luminance; the g^4 bolometric factor is applied by the
// caller, so colour and brightness stay separable.

static float3 blackbodyRGB(float kelvin)
{
    float T = clamp(kelvin, 1000.0, 40000.0);
    float t = 1000.0 / T;
    float t2 = t * t, t3 = t2 * t;

    float x = (T < 4000.0)
        ? (-0.2661239 * t3 - 0.2343589 * t2 + 0.8776956 * t + 0.179910)
        : (-3.0258469 * t3 + 2.1070379 * t2 + 0.2226347 * t + 0.240390);

    float x2 = x * x, x3 = x2 * x;
    float y;
    if (T < 2222.0)      y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683;
    else if (T < 4000.0) y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867;
    else                 y =  3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483;

    y = max(y, 1e-4);
    float3 XYZ = float3(x / y, 1.0, (1.0 - x - y) / y);

    float3 rgb = float3(
        dot(XYZ, float3( 3.2404542, -1.5371385, -0.4985314)),
        dot(XYZ, float3(-0.9692660,  1.8760108,  0.0415560)),
        dot(XYZ, float3( 0.0556434, -0.2040259,  1.0572252)));

    rgb = max(rgb, 0.0);
    float lum = max(dot(rgb, float3(0.2126, 0.7152, 0.0722)), 1e-5);
    return rgb / lum;
}

// ============================================================ sky
//
// Procedural starfield plus a Milky Way band. Stars are Planckian too, so the
// same gravitational blueshift machinery applies to them.

static float3 starfield(float3 d)
{
    float3 col = float3(0.0);

    for (int layer = 0; layer < 3; ++layer) {
        float scale = 38.0 + 57.0 * float(layer);
        float3 p = d * scale;
        float3 cell = floor(p);
        float3 h = hash33(cell + float(layer) * 17.0);

        // Star sits well inside the cell so no 3x3 neighbourhood is needed.
        float3 centre = cell + 0.25 + 0.5 * h;
        float dist = length(p - centre);

        float present = step(0.88, hash11(h.x * 311.0 + float(layer) * 7.3));
        // Roughly a power-law luminosity function: many faint, few brilliant.
        float mag  = pow(h.y, 3.0) * 6.0 + 0.05;
        float core = exp(-dist * dist * (300.0 + 240.0 * h.z));
        float halo = exp(-dist * 7.0) * 0.035;

        float T = mix(2700.0, 22000.0, pow(h.z, 1.7));
        col += present * mag * (core + halo) * blackbodyRGB(T);
    }

    // Galactic band: a great circle with fbm-modulated dust and star clouds.
    float3 axis = normalize(float3(0.31, 0.86, -0.41));
    float band = 1.0 - abs(dot(d, axis));
    float bandMask = pow(smoothstep(0.70, 1.0, band), 2.5);
    float dust = fbm2(d.xz * 3.1 + d.y * 2.3) * fbm2(d.yx * 5.7 - d.z);
    col += bandMask * dust * float3(0.10, 0.10, 0.14);
    col += bandMask * pow(dust, 3.0) * float3(0.20, 0.17, 0.13);

    return col;
}

// ============================================================ disk

struct DiskSample {
    float3 colour;   // premultiplied radiance
    float  alpha;
};

// r      : Boyer-Lindquist / Schwarzschild radius of the equatorial crossing
// pdir   : unit position direction (lies in the y = 0 plane)
// nFwd   : photon propagation direction (emitter -> camera) in the local
//          static orthonormal frame
static DiskSample sampleDisk(float r, float3 pdir, float3 nFwd, float time)
{
    DiskSample s;
    s.colour = float3(0.0);
    s.alpha  = 0.0;

    if (r < R_IN || r > R_OUT) return s;

    float f = 1.0 - RS / r;                       // metric lapse squared

    // --- redshift factor g = E_obs / E_emit -------------------------------
    // Keplerian circular orbit: Omega = r^-3/2, locally measured speed
    // v = sqrt(M/r) / sqrt(1 - rs/r)  ->  exactly 0.5 c at r = 6M.
    float v    = sqrt(1.0 / r) / sqrt(f);
    float gam  = 1.0 / sqrt(max(1.0 - v * v, 1e-6));
    float3 ephi = normalize(cross(float3(0.0, 1.0, 0.0), pdir));
    float3 beta = (SPIN_DIR * v) * ephi;

#if DOPPLER_BEAMING
    float g = sqrt(f) / (gam * (1.0 - dot(beta, nFwd)));
#else
    float g = sqrt(f);
#endif
    g = clamp(g, 0.02, 6.0);

    // --- Novikov-Thorne temperature profile -------------------------------
    // T(r) = T_peak * x^(3/4) (1 - sqrt(x))^(1/4) / 0.4879,  x = r_isco / r.
    // The 0.4879 normalises the profile's maximum (at r = 49/36 r_isco) to 1.
    float x    = R_IN / r;
    float prof = pow(x, 0.75) * pow(max(1.0 - sqrt(x), 0.0), 0.25) / 0.4879;
    float Temit = T_PEAK * prof;
    float Tobs  = g * Temit;

    // Bolometric: I_obs / I_emit = g^4, and a blackbody stays a blackbody.
    float lum = pow(Tobs / T_PEAK, 4.0) * DISK_BRIGHT;
    float3 col = blackbodyRGB(max(Tobs, 900.0)) * lum;

    // --- structure --------------------------------------------------------
    // Advected with the *local* Keplerian angular velocity, so the pattern
    // shears differentially exactly as a real disk does.
    float omega = pow(r, -1.5) * TIME_SCALE;
    float2 q = rot2(-omega * time) * pdir.xz;
    float dens = fbm2(q * (4.5 + 40.0 / r) + float2(0.0, r * 0.35));
    dens = 0.62 + 0.55 * dens;
    // Fine spiral filaments.
    float fil = fbm2(q * 22.0 + float2(r * 1.7, -r));
    dens *= 0.80 + 0.40 * fil;

    col *= dens;

    // Optical depth of a slab of scale height H crossed at an oblique angle:
    // tau scales as 1/|sin(angle to the plane)|, so a grazing ray sees far more
    // material. This is what gives the disk a soft, thick edge without any
    // fake glow, and it thins out correctly near the rim.
    float edge = smoothstep(0.0, 0.30, r - R_IN) *
                 (1.0 - smoothstep(R_OUT - 6.0, R_OUT, r));
    float slant = max(abs(nFwd.y), 0.055);
    float tau = TAU0 * edge * dens / slant;
    s.alpha  = 1.0 - exp(-tau);
    s.colour = col * s.alpha;
    return s;
}

// ============================================================ geodesic

// u'' = -u + 3 M u^2, with M = 1.
static inline float accel(float u)
{
    return -u + 3.0 * u * u;
}

static inline float hermite(float a, float b, float m0, float m1, float h, float t)
{
    float t2 = t * t, t3 = t2 * t;
    return (2.0 * t3 - 3.0 * t2 + 1.0) * a
         + (t3 - 2.0 * t2 + t) * h * m0
         + (-2.0 * t3 + 3.0 * t2) * b
         + (t3 - t2) * h * m1;
}

static inline float hermiteD(float a, float b, float m0, float m1, float h, float t)
{
    float t2 = t * t;
    return ((6.0 * t2 - 6.0 * t) * a
          + (3.0 * t2 - 4.0 * t + 1.0) * h * m0
          + (-6.0 * t2 + 6.0 * t) * b
          + (3.0 * t2 - 2.0 * t) * h * m1) / h;
}

// Traces one backward ray from a static observer at `cam` in local direction
// `dir`, and returns the radiance reaching the camera.
static float3 trace(float3 cam, float3 dir, float time)
{
    float r0 = length(cam);
    float3 e1 = cam / r0;                     // radial basis vector of the plane
    float cr = dot(dir, e1);
    float3 tang = dir - cr * e1;
    float ct = length(tang);

    // Purely radial ray: nudge so the orbital plane stays well defined.
    if (ct < 1e-6) {
        float3 tmp = abs(e1.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        tang = normalize(cross(e1, tmp)) * 1e-6;
        ct = 1e-6;
    }
    float3 e2 = tang / ct;                    // direction of increasing phi

    // Equatorial crossings: y(phi) = A cos(phi) + B sin(phi) = 0, so they sit
    // exactly at phi = atan2(-A, B) + n*pi. No root finding needed.
    float A = e1.y, B = e2.y;
    bool hasCross = (A * A + B * B) > 1e-12;
    float phiCross0 = hasCross ? atan2(-A, B) : 0.0;

    float u  = 1.0 / r0;
    // du/dphi for a photon aimed in local direction (cr, ct) by a static
    // observer: radial proper length is dr/sqrt(1-rs/r), tangential is r dphi.
    float du = -u * sqrt(1.0 - RS * u) * cr / ct;

    float phi = 0.0;
    float3 acc = float3(0.0);
    float trans = 1.0;                        // remaining transmittance
    bool captured = false;
    float3 escapeDir = dir;
    bool escaped = false;

    for (int i = 0; i < MAX_STEPS; ++i) {
        if (u > 0.5) { captured = true; break; }              // r < rs
        if (trans < 0.004) break;

        // Adaptive in phi: tighten hard through the photon sphere, where the
        // ring's sharpness is decided.
        float h = max(0.08 / (1.0 + 32.0 * u * u), 0.004);

        float k1u = du,              k1d = accel(u);
        float k2u = du + 0.5 * h * k1d, k2d = accel(u + 0.5 * h * k1u);
        float k3u = du + 0.5 * h * k2d, k3d = accel(u + 0.5 * h * k2u);
        float k4u = du + h * k3d,       k4d = accel(u + h * k3u);

        float un  = u  + (h / 6.0) * (k1u + 2.0 * k2u + 2.0 * k3u + k4u);
        float dun = du + (h / 6.0) * (k1d + 2.0 * k2d + 2.0 * k3d + k4d);

        // --- equatorial crossing inside this step? (h < pi, so at most one)
        if (hasCross && un > 0.0) {
            float n  = floor((phi - phiCross0) / M_PI_F) + 1.0;
            float pc = phiCross0 + n * M_PI_F;
            if (pc > phi && pc <= phi + h) {
                float t  = (pc - phi) / h;
                float uc = hermite(u, un, du, dun, h, t);
                if (uc > 1.0 / (R_OUT + 1.0) && uc < 1.0 / R_IN + 1e-4 && uc < 0.5) {
                    float duc = hermiteD(u, un, du, dun, h, t);
                    float rc  = 1.0 / uc;

                    float cs = cos(pc), sn = sin(pc);
                    float3 pdir = cs * e1 + sn * e2;          // unit, y ~ 0
                    float3 tdir = -sn * e1 + cs * e2;         // e_phi of the plane

                    // Backward tangent in the static observer's orthonormal
                    // frame: radial component picks up the 1/sqrt(f) stretch.
                    float drdphi = -duc / (uc * uc);
                    float fc = max(1.0 - RS * uc, 1e-5);
                    float3 tb = normalize((drdphi / sqrt(fc)) * pdir + rc * tdir);
                    float3 nFwd = -tb;                        // emitter -> camera

                    DiskSample ds = sampleDisk(rc, normalize(float3(pdir.x, 0.0, pdir.z)),
                                               nFwd, time);
                    acc   += trans * ds.colour;
                    trans *= (1.0 - ds.alpha);
                }
            }
        }

        // --- escape? u crosses zero at a finite phi: that is the asymptote.
        // Root-find it inside the step rather than testing u against some
        // small radius, which a single step can jump clean over (that produced
        // concentric banding in the lensed sky).
        if (un <= 0.0) {
            float t0 = 0.0, t1 = 1.0;
            for (int k = 0; k < 12; ++k) {
                float tm = 0.5 * (t0 + t1);
                if (hermite(u, un, du, dun, h, tm) > 0.0) t0 = tm; else t1 = tm;
            }
            float pinf = phi + 0.5 * (t0 + t1) * h;
            // At u = 0 the motion is purely radial, so the outgoing direction
            // is exactly the position direction at the asymptotic angle.
            escapeDir = cos(pinf) * e1 + sin(pinf) * e2;
            escaped = true;
            break;
        }

        phi += h;
        u = un;
        du = dun;
    }

    // A ray that exhausted the step budget is winding near the photon sphere;
    // treat it as captured rather than emitting a bogus direction.
    if (escaped && trans > 0.004) {
        // Light falling in from infinity is blueshifted for the static camera;
        // blackbody stars simply shift temperature by the same factor.
        float gs = 1.0 / sqrt(1.0 - RS / length(cam));
        acc += trans * starfield(escapeDir) * pow(gs, 4.0);
    }

    return acc;
}

// ============================================================ tonemap

static float3 aces(float3 x)
{
    const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

// ============================================================ entry

float4 shaderMain(float2 fragCoord, Uniforms u)
{
    float2 res = iResolution;
    float time = iTime;

    // Camera: static observer, orbiting on mouse drag.
    float az   = 0.35;
    float incl = CAM_INCL;
    if (iMouse.x > 1.0 || iMouse.y > 1.0) {
        az   = (iMouse.x / res.x - 0.5) * 6.2831853;
        incl = (iMouse.y / res.y - 0.5) * 2.6;
        incl = clamp(incl, -1.45, 1.45);
        if (abs(incl) < 0.006) incl = 0.006;   // keep the orbital plane defined
    }

    float3 cam = CAM_R * float3(cos(incl) * sin(az), sin(incl), cos(incl) * cos(az));
    float3 fwd = normalize(-cam);
    float3 rgt = normalize(cross(fwd, float3(0.0, 1.0, 0.0)));
    float3 upv = cross(rgt, fwd);

    float tanHalf = tan(0.5 * FOV);
    float3 acc = float3(0.0);

    for (int sy = 0; sy < AA; ++sy) {
        for (int sx = 0; sx < AA; ++sx) {
            float2 jitter = (AA == 1) ? float2(0.5)
                                      : (float2(float(sx), float(sy)) + 0.5) / float(AA);
            float2 p = (fragCoord + jitter - 0.5 * res) / res.y;
            float3 dir = normalize(fwd + (2.0 * p.x * tanHalf) * rgt
                                       + (2.0 * p.y * tanHalf) * upv);
            acc += trace(cam, dir, time);
        }
    }
    acc /= float(AA * AA);

    float3 col = aces(acc * EXPOSURE);
    col = pow(col, float3(1.0 / 2.2));

    // Mild ordered dither to kill banding in the dark falloff.
    col += (hash12(fragCoord + fract(time)) - 0.5) / 255.0;

    return float4(col, 1.0);
}
