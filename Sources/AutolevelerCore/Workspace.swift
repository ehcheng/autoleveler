import Foundation
import Darwin

final class Workspace {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Autoleveler", isDirectory: true)
    let directory: URL
    let descriptor: Int32
    var partial: URL?
    init() throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        Self.recover()
        directory = Self.root.appendingPathComponent("job-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw AutolevelerError.message("Could not create a processing workspace.")
        }
    }
    func stage(in destination: URL, extension suffix: String) throws -> URL {
        let name = ".autoleveler-" + directory.lastPathComponent + ".partial." + suffix
        let url = destination.appendingPathComponent(name)
        let manifest = ["partial": url.path, "name": name]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        partial = url
        return url
    }
    deinit {
        if let partial { try? FileManager.default.removeItem(at: partial) }
        try? FileManager.default.removeItem(at: directory)
        flock(descriptor, LOCK_UN); close(descriptor)
    }
    static func recover() {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for folder in directories where folder.lastPathComponent.hasPrefix("job-") {
            let descriptor = open(folder.appendingPathComponent("lock").path, O_RDWR)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
               let manifest = try? JSONDecoder().decode([String: String].self, from: data),
               let path = manifest["partial"], let name = manifest["name"],
               name.hasPrefix(".autoleveler-" + folder.lastPathComponent + ".partial."),
               URL(fileURLWithPath: path).lastPathComponent == name {
                try? manager.removeItem(atPath: path)
            }
            try? manager.removeItem(at: folder)
            flock(descriptor, LOCK_UN)
        }
    }
}
