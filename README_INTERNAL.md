# Metal Shader Viewer

A native macOS app (Swift + AppKit + Metal) for shader-art coding. Pick a `.metal`
fragment shader, and it renders fullscreen in a separate output window.

This is the Metal counterpart to the `openglcli` C# tool: same idea, no OpenGL,
no OpenTK, no third-party dependencies. Metal and its runtime shader compiler are
part of macOS, so nothing needs to be vendored.

## Build & run

```bash
./build.sh
```

Produces `build/MetalShaderViewer.app`. Open it, or launch it straight onto a shader:

```bash
open -a "$PWD/build/MetalShaderViewer.app" --args "$PWD/Examples/shaderwaves2.metal"
```

Requires macOS 14+. Only the Command Line Tools are needed — shaders are compiled
at runtime with `MTLDevice.makeLibrary(source:)`, so a full Xcode install and the
offline `metal` compiler are not required.

## Writing a shader

Shaders are compiled at runtime, so you can edit and reload without rebuilding the
app. Your file only needs to define one function:

```metal
float4 shaderMain(float2 fragCoord, Uniforms u)
{
    float2 uv = fragCoord / iResolution;
    return float4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
}
```

The app prepends a prelude (see `Sources/MetalShaderViewer/ShaderPrelude.swift`)
that supplies:

| Symbol | Type | Meaning |
| --- | --- | --- |
| `iResolution` | `float2` | Drawable size in pixels |
| `iTime` | `float` | Seconds since load (stops while paused) |
| `iMouse` | `float2` | Cursor position in pixels, bottom-left origin |
| `iFrame` | `float` | Frames rendered |

`fragCoord` is already flipped to GLSL's bottom-left origin, so ported GLSL comes
out the right way up.

**One difference from GLSL:** Metal has no mutable global variables, so the `iXxx`
macros resolve against a parameter named `u`. Any helper function that reads them
must take a trailing `Uniforms u` and pass it down. `Examples/shaderwaves2.metal`
shows the pattern.

## Controls

The output window is a square 800 x 800 canvas by default, which is the usual
framing for shader art.

- **Choose Shader…** (⌘O) — pick a `.metal` file; the output window opens on success
- **Reload** — recompile, keeping the current time
- **Auto-reload on save** — watches the file and recompiles on write
- **Canvas** — output size in points. With **Keep square** on (the default) the
  window is locked to 1:1, so dragging a corner keeps it square and the height
  field follows the width. Turn it off for a free aspect ratio. Resizing the
  window by hand updates the fields too.
- **Render at** — render below the canvas size and upscale
- **Drawable** readout — the resulting pixel count. Canvas size is in *points*, so
  on a Retina display an 800 pt canvas is 1600 x 1600 real pixels. Set **Render at**
  to 50% if you want the drawable to match the canvas number exactly.
- **Pause / Resume** — freezes time and stops the render loop entirely
- Compiler errors appear in the log pane in red, with your own line numbers
- Move the mouse over the output window to drive `iMouse`

## Performance work

The render path is built around not doing work that does not reach the screen.

**Draw path**
- Fullscreen *triangle* generated from `vertex_id` alone — no vertex buffer, no
  index buffer, no bindings. A fullscreen quad rasterizes its diagonal twice; a
  triangle does not.
- Uniforms go through `setFragmentBytes` (24 bytes, well under the 4 KB limit).
  Metal inlines them into the command buffer, so there is no uniform buffer, no
  triple-buffered ring allocation, and no CPU/GPU semaphore to manage.
- `loadAction = .dontCare` — the shader writes every pixel, so the previous
  contents are never pulled back into tile memory.
- No depth buffer, no stencil, no blending, no MSAA, and `framebufferOnly = true`
  so the driver can pick the cheapest texture configuration.
- The CPU never calls `waitUntilCompleted`; it runs ahead and queues the next
  frame while the GPU is still on the current one.
- `nextDrawable()` is acquired as late as possible — it blocks when all drawables
  are in flight, so everything preparable is prepared first.

**Frame pacing**
- `CADisplayLink` on `.common` run loop mode: paced to the display the window is
  actually on, and still ticking during live resize and menu tracking.
- Triple buffering (`maximumDrawableCount = 3`) with vsync on, so no frame is
  rendered just to be dropped.
- The loop is fully stopped — not idling — whenever there is nothing to draw:
  paused, no pipeline, zero-sized, or the window is occluded/minimised. Occlusion
  is the big one; a covered window would otherwise keep the GPU at full tilt.
- One `autoreleasepool` per frame, since `CAMetalDrawable` is autoreleased and
  would otherwise pile up until the run loop drains.

**Compilation**
- Shader compilation and pipeline creation are both asynchronous, so a slow
  shader never blocks the UI or stalls the frame in flight.
- Fast-math is enabled (`MTLCompileOptions.mathMode = .fast`).
- Swift release builds use `-Ounchecked`.

**Render scale**
The largest lever for expensive shaders, so it is exposed in the UI. Cost scales
with pixel count, so 50% is roughly 4x cheaper. Measured on this machine with
`shaderwaves2.metal` (12/36-iteration wave sums inside a 64-step raymarch):

| Drawable | GPU time | Headroom |
| --- | --- | --- |
| 1600x1600 | 17.4 ms | 57 fps |
| 1200x1200 | 10.0 ms | 100 fps |
| 800x800 | 5.1 ms | 198 fps |
| 400x400 | 1.7 ms | 602 fps |

Note the default 800 pt canvas is 1600 x 1600 pixels on a Retina display, which
puts the two raymarching examples just under 60 fps at 100%. Drop **Render at** to
75% or 50% for comfortable headroom — at this canvas size the upscale is hard to
notice on organic content.

## Examples

All three shaders from `openglcli/example/` are ported. Porting notes are in each
file header.

| File | Source | Cost @1600x1600 |
| --- | --- | --- |
| `Examples/shader.metal` | `shader.frag` — cosine-palette kaleidoscope | 2.6 ms (380 fps) |
| `Examples/shader2.metal` | `shader2.frag` — raymarched octagram tunnel | 16.3 ms (61 fps) |
| `Examples/shaderwaves2.metal` | `shaderwaves2.frag` — ocean (afl_ext, MIT) | 17.4 ms (57 fps) |

### GLSL to MSL gotchas hit while porting

Worth knowing if you port more of your own shaders:

- **`mod` is not `fmod`.** GLSL's `mod(x,y)` follows floor, so the result takes the
  divisor's sign; C/Metal's `fmod` truncates, so it takes the dividend's sign. They
  agree only for positive operands. `shader2.frag` folds space with
  `mod(pos - 2.0, 4.0)`, which goes negative every frame — using `fmod` visibly
  collapses the tunnel. `shader2.metal` spells out `x - y * floor(x / y)` instead.
- **`gl_FragCoord` is bottom-left, Metal's `[[position]]` is top-left.** The viewer's
  prelude flips this for you, so ported shaders come out the right way up.
- **Matrix constructors are column-major in both**, so `mat2(c, s, -s, c)` becomes
  `float2x2(float2(c, s), float2(-s, c))` — each *group* is a column, not a row.
- **`v * M` means row-vector times matrix in both languages**, so the common
  `pos.xy *= rot(a)` idiom carries over unchanged (verified, not assumed).
- **Scalar broadcast is stricter.** `max(q, 0.0)` on a vector may not compile;
  write `max(q, float3(0.0))`.
- **No mutable globals**, hence the `Uniforms u` threading described above.

## Layout

```
Sources/MetalShaderViewer/
  main.swift                    NSApplication entry point
  AppDelegate.swift             Menu bar, lifecycle, file arguments
  ControlWindowController.swift Control panel, file watching
  RenderWindowController.swift  Output window
  MetalRenderer.swift           CAMetalLayer view and render loop
  ShaderCompiler.swift          Runtime MSL compilation
  ShaderPrelude.swift           Injected prelude and Uniforms layout
Examples/shaderwaves2.metal
build.sh
```
