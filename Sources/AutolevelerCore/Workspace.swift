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
        let newDirectory = Self.root.appendingPathComponent("job-" + UUID().uuidString, isDirectory: true)
        directory = newDirectory
        descriptor = try Self.coordinated {
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: false)
            let descriptor = open(newDirectory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                try? FileManager.default.removeItem(at: newDirectory)
                throw AutolevelerError.message("Could not create a processing workspace.")
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                try? FileManager.default.removeItem(at: newDirectory)
                throw AutolevelerError.message("Could not lock a processing workspace.")
            }
            return descriptor
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
    // Serialize creation with recovery so another instance cannot reap a newly opened lock.
    private static func coordinated<T>(wait: Bool = true, _ action: () throws -> T) throws -> T {
        let descriptor = open(root.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AutolevelerError.message("Could not coordinate temporary storage.") }
        defer { close(descriptor) }
        guard flock(descriptor, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            throw AutolevelerError.message("Temporary storage is in use.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }
    static func recover() {
        try? coordinated(wait: false) {
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
}
