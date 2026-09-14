import Foundation
import Metal

enum ShaderCompileError: LocalizedError {
    case unreadableFile(URL, Error)
    case missingEntryPoint
    case compilation(String)
    case missingFunction(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let url, let error):
            return "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        case .missingEntryPoint:
            return """
            Shader does not define an entry point.

            Expected:
                float4 \(ShaderPrelude.entryPoint)(float2 fragCoord, Uniforms u)
            """
        case .compilation(let message):
            return message
        case .missingFunction(let name):
            return "Compiled library has no function named \(name)."
        }
    }
}

/// Turns a `.metal` file on disk into a ready-to-bind render pipeline state.
struct ShaderCompiler {
    let device: MTLDevice
    let pixelFormat: MTLPixelFormat

    func loadSource(at url: URL) throws -> String {
        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ShaderCompileError.unreadableFile(url, error)
        }
        guard body.contains(ShaderPrelude.entryPoint) else {
            throw ShaderCompileError.missingEntryPoint
        }
        return ShaderPrelude.source + "\n" + body
    }

    /// Compiles off the main thread and reports back on the main queue, so a slow
    /// shader never freezes the UI or stalls the frame currently in flight.
    func makePipeline(source: String,
                      completion: @escaping (Result<MTLRenderPipelineState, Error>) -> Void) {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        } else {
            options.fastMathEnabled = true
        }

        let finish: (Result<MTLRenderPipelineState, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        device.makeLibrary(source: source, options: options) { library, error in
            if let error {
                finish(.failure(ShaderCompileError.compilation(Self.clean(error))))
                return
            }
            guard let library else {
                finish(.failure(ShaderCompileError.compilation("Unknown compilation failure.")))
                return
            }
            guard let vertexFunction = library.makeFunction(name: ShaderPrelude.vertexFunctionName) else {
                finish(.failure(ShaderCompileError.missingFunction(ShaderPrelude.vertexFunctionName)))
                return
            }
            guard let fragmentFunction = library.makeFunction(name: ShaderPrelude.fragmentFunctionName) else {
                finish(.failure(ShaderCompileError.missingFunction(ShaderPrelude.fragmentFunctionName)))
                return
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "ShaderArtPipeline"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            // No depth, no stencil, no blending, no MSAA: the shader owns every pixel.
            descriptor.rasterSampleCount = 1

            device.makeRenderPipelineState(descriptor: descriptor) { pipeline, error in
                if let pipeline {
                    finish(.success(pipeline))
                } else {
                    finish(.failure(ShaderCompileError.compilation(
                        error.map(Self.clean) ?? "Pipeline creation failed.")))
                }
            }
        }
    }

    /// Metal wraps diagnostics in a long NSError description; the useful part is
    /// the compiler log itself.
    private static func clean(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        guard let range = text.range(of: "program_source:") else { return text }
        return String(text[range.lowerBound...])
            .replacingOccurrences(of: "program_source:", with: "line ")
    }
}
