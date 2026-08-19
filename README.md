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

**Render scale**
Measured on base M4 Mac with
`shaderwaves2.metal` (12/36-iteration wave sums inside a 64-step raymarch):

| Drawable | GPU time | Headroom |
| --- | --- | --- |
| 1600x1600 | 17.4 ms | 57 fps |
| 1200x1200 | 10.0 ms | 100 fps |
| 800x800 | 5.1 ms | 198 fps |
| 400x400 | 1.7 ms | 602 fps |

Note the default 800 pt canvas is 1600 x 1600 pixels on a 13.6" Retina display, which
puts the two raymarching examples just under 60 fps at 100%. Drop **Render at** to
75% or 50% for comfortable headroom — at this canvas size the upscale is hard to
notice on organic content.

## Examples

All three shaders are ported from `openglcli/example/`:

| File | Source | Cost @1600x1600 |
| --- | --- | --- |
| `Examples/shader.metal` | `shader.frag` — cosine-palette kaleidoscope | 2.6 ms (380 fps) |
| `Examples/shader2.metal` | `shader2.frag` — raymarched octagram tunnel | 16.3 ms (61 fps) |
| `Examples/shaderwaves2.metal` | `shaderwaves2.frag` — ocean (afl_ext, MIT) | 17.4 ms (57 fps) |


