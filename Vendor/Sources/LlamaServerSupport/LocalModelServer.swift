import Foundation
import LlamaServer

/// llama.cpp's llama-server, running in-process. Its OpenAI-compatible endpoint (streaming, Jinja chat templates,
/// tool calls) serves on-device models to pi like any other provider.
public enum LocalModelServer {
    /// Runs the server with llama-server's command-line arguments (without the program name). Blocks until the server
    /// stops; call it on a dedicated thread.
    public static func run(arguments: [String]) -> Int32 {
        let argv = (["llama-server"] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var pointers = argv + [nil]
        return pointers.withUnsafeMutableBufferPointer { buffer in
            pi_llama_server_main(Int32(argv.count), buffer.baseAddress)
        }
    }

    /// Asks a running server to shut down; `run` then returns.
    public static func terminate() {
        pi_llama_server_terminate()
    }
}
