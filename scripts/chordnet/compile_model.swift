// Compiles a Core ML package into the .mlmodelc the app loads (no Xcode needed).
//   swift scripts/chordnet/compile_model.swift Resources/ChordNet.mlpackage build/ChordNet.mlmodelc
import Foundation
import CoreML

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: compile_model.swift <in.mlpackage> <out.mlmodelc>"); exit(2) }
do {
    let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
    let out = URL(fileURLWithPath: args[2])
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: compiled, to: out)
    print("✓ Compiled \(args[2])")
} catch {
    print("couldn't compile \(args[1]): \(error)"); exit(1)
}
