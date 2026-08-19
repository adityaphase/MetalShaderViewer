import Foundation
import simd

/// Uniform block handed to the fragment shader every frame.
///
/// Layout must stay byte-identical to `struct Uniforms` in `ShaderPrelude.source`.
/// float2 is 8-byte aligned on both sides, so this packs to 24 bytes with no padding.
struct Uniforms {
    var resolution: SIMD2<Float>
    var mouse: SIMD2<Float>
    var time: Float
    var frame: Float
}

enum ShaderPrelude {
    /// Name of the function a user shader file is expected to define.
    static let entryPoint = "shaderMain"

    static let vertexFunctionName = "msv_vertex"
    static let fragmentFunctionName = "msv_fragment"

    /// Prepended to every shader file before compilation.
    ///
    /// It supplies the uniform block, the Shadertoy-style `iTime` / `iResolution` /
    /// `iMouse` aliases, a vertex stage that needs no vertex buffer, and the real
    /// fragment entry point that forwards to the user's `shaderMain`.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float2 mouse;
        float  time;
        float  frame;
    };

    struct MSVVertexOut {
        float4 position [[position]];
    };

    // Fullscreen triangle generated from the vertex id alone: no vertex buffer,
    // no index buffer, no binding cost, and no diagonal seam to rasterize twice.
    vertex MSVVertexOut msv_vertex(uint vid [[vertex_id]])
    {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        MSVVertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // GLSL-style aliases. They resolve against a parameter named `u`, so every
    // helper function that touches them must take a trailing `Uniforms u`.
    #define iResolution u.resolution
    #define iTime       u.time
    #define iMouse      u.mouse
    #define iFrame      u.frame

    float4 shaderMain(float2 fragCoord, Uniforms u);

    fragment float4 msv_fragment(MSVVertexOut in [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(0)]])
    {
        Uniforms u = uniforms;
        // Metal's [[position]] origin is top-left; GLSL's gl_FragCoord is
        // bottom-left. Flip so ported GLSL art comes out the right way up.
        float2 fragCoord = float2(in.position.x, u.resolution.y - in.position.y);
        return shaderMain(fragCoord, u);
    }

    #line 1
    """
}
