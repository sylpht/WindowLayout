import Foundation
import CoreGraphics

var passed = 0, failed = 0
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("WindowLayout-storage-tests-\(UUID().uuidString)")
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() { passed += 1; print("PASS \(name)") }
        else { failed += 1; print("FAIL \(name)") }
    } catch { failed += 1; print("FAIL \(name): \(error)") }
}
func fixture(_ name: String) -> LayoutProfile {
    LayoutProfile(id: UUID(), displaySignature: "test", name: name,
                  capturedAt: Date(timeIntervalSince1970: 1700000000), windows: [], screenFrames: [])
}
func file(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathComponent("profiles.json") }
func locked(_ url: URL, _ body: () throws -> Bool) throws -> Bool {
    let parent = url.deletingLastPathComponent()
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
    return try body()
}
func names(_ p: [LayoutProfile]) -> Set<String> { Set(p.map(\.name)) }

check("failed creation leaves no memory-only profile") {
    let parent = root.appendingPathComponent("blocked")
    try Data("file, not directory".utf8).write(to: parent)
    let manager = LayoutManager(storageURL: parent.appendingPathComponent("profiles.json"))
    manager.addProfile(fixture("unsaved"))
    return manager.allProfiles.isEmpty
}
check("failed rename preserves memory and original file") {
    let url = file("rename")
    let manager = LayoutManager(storageURL: url)
    let p = fixture("original")
    manager.addProfile(p)
    let original = try Data(contentsOf: url)
    return try locked(url) {
        manager.renameProfile(id: p.id, to: "changed")
        return try manager.profile(id: p.id)?.name == "original" && (Data(contentsOf: url)) == original
    }
}
check("failed delete preserves memory and original file") {
    let url = file("delete")
    let manager = LayoutManager(storageURL: url)
    let p = fixture("keep")
    manager.addProfile(p)
    let original = try Data(contentsOf: url)
    return try locked(url) {
        manager.deleteProfile(id: p.id)
        return try manager.profile(id: p.id) != nil && (Data(contentsOf: url)) == original
    }
}
check("corrupt local file is preserved when saving") {
    let url = file("corrupt")
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("{truncated profile data".utf8)
    try original.write(to: url)
    let manager = LayoutManager(storageURL: url)
    manager.addProfile(fixture("new"))
    return try manager.allProfiles.isEmpty && (Data(contentsOf: url)) == original
}
check("healthy cloud does not overwrite corrupt local file at startup") {
    let url = file("corrupt-with-cloud")
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("{broken local".utf8)
    try original.write(to: url)
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent("cloud-for-corrupt"), alwaysEnabled: true)
    sync.push(profiles: [fixture("cloud")])
    let manager = LayoutManager(storageURL: url, sync: sync)
    sync.syncDispatchQueue.sync {}
    return try manager.allProfiles.isEmpty && (Data(contentsOf: url)) == original
}
check("failed local adoption retains old active profiles") {
    let url = file("adoption")
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent("adoption-cloud"), alwaysEnabled: true)
    let manager = LayoutManager(storageURL: url, sync: sync)
    let local = fixture("local")
    manager.addProfile(local)
    sync.syncDispatchQueue.sync {}
    let original = try Data(contentsOf: url)
    sync.mergeAndPush(localSnapshot: [fixture("remote")])
    return try locked(url) {
        manager.mergeRemoteIntoLocal()
        return try names(manager.allProfiles) == ["local"] && (Data(contentsOf: url)) == original
    }
}
check("enabling sync remerges immediately before queued write") {
    let folder = root.appendingPathComponent("kick-cloud")
    let a = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let b = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let p1 = fixture("P1"), p2 = fixture("P2")
    a.push(profiles: [p1])
    let manager = LayoutManager(storageURL: file("kick-local"), sync: a)
    a.syncDispatchQueue.sync {}
    a.syncDispatchQueue.suspend()
    manager.kickPush()
    b.mergeAndPush(localSnapshot: [p2])
    a.syncDispatchQueue.resume()
    a.syncDispatchQueue.sync {}
    return names(b.pull() ?? []) == ["P1", "P2"]
}
check("startup queued write preserves intervening remote additions") {
    let folder = root.appendingPathComponent("startup-cloud")
    let a = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let b = iCloudSync(syncFolderURL: folder, alwaysEnabled: true)
    let p1 = fixture("P1"), pa = fixture("PA"), p2 = fixture("P2")
    a.push(profiles: [p1])
    let url = file("startup-local")
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try iCloudSync.makeEncoder().encode([p1, pa]).write(to: url)
    a.syncDispatchQueue.suspend()
    let manager = LayoutManager(storageURL: url, sync: a)
    b.mergeAndPush(localSnapshot: [p2])
    a.syncDispatchQueue.resume()
    a.syncDispatchQueue.sync {}
    withExtendedLifetime(manager) {}
    return names(b.pull() ?? []) == ["P1", "PA", "P2"]
}

func deliverMainCallbacks() {
    var delivered = false
    DispatchQueue.main.async { delivered = true }
    let deadline = Date().addingTimeInterval(2)
    while !delivered && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(delivered, "main queue did not drain")
}
check("failed mutation emits no layout change or cloud write") {
    deliverMainCallbacks()
    let url = file("failed-notification")
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent("failed-notification-cloud"), alwaysEnabled: true)
    let manager = LayoutManager(storageURL: url, sync: sync)
    let p = fixture("keep")
    manager.addProfile(p)
    sync.syncDispatchQueue.sync {}
    deliverMainCallbacks()
    let originalCloud = try Data(contentsOf: sync.syncFileURL!)
    var changes = 0
    let observer = NotificationCenter.default.addObserver(forName: LayoutManager.didChangeNotification, object: nil, queue: nil) { _ in changes += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    let unchanged = try locked(url) {
        manager.renameProfile(id: p.id, to: "unsaved")
        sync.syncDispatchQueue.sync {}
        deliverMainCallbacks()
        return try names(manager.allProfiles) == ["keep"] && Data(contentsOf: sync.syncFileURL!) == originalCloud
    }
    return unchanged && changes == 0 && manager.lastStorageError != nil
}
check("late cloud adoption preserves a newer local rename") {
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent("late-rename-cloud"), alwaysEnabled: true)
    let manager = LayoutManager(storageURL: file("late-rename"), sync: sync)
    let p = fixture("original"), remote = fixture("remote")
    manager.addProfile(p)
    sync.syncDispatchQueue.sync {}
    sync.mergeAndPush(localSnapshot: [remote])
    manager.kickPush()
    sync.syncDispatchQueue.sync {}
    manager.renameProfile(id: p.id, to: "new-name")
    sync.syncDispatchQueue.sync {}
    deliverMainCallbacks()
    return names(manager.allProfiles) == ["new-name", "remote"]
        && LayoutManager(storageURL: manager.storageURL).profile(id: p.id)?.name == "new-name"
}
check("late cloud adoption failure preserves active memory and file") {
    let url = file("late-adoption-failure")
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent("late-adoption-failure-cloud"), alwaysEnabled: true)
    let manager = LayoutManager(storageURL: url, sync: sync)
    let p = fixture("local")
    manager.addProfile(p)
    sync.syncDispatchQueue.sync {}
    deliverMainCallbacks()
    let original = try Data(contentsOf: url)
    sync.mergeAndPush(localSnapshot: [fixture("remote")])
    manager.kickPush()
    sync.syncDispatchQueue.sync {}
    return try locked(url) {
        deliverMainCallbacks()
        return try names(manager.allProfiles) == ["local"] && Data(contentsOf: url) == original
            && manager.lastStorageError != nil
    }
}
func switchableSync(_ name: String, _ body: (iCloudSync) throws -> Bool) throws -> Bool {
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: iCloudSync.prefKey)
    defaults.set(true, forKey: iCloudSync.prefKey)
    let sync = iCloudSync(syncFolderURL: root.appendingPathComponent(name), alwaysEnabled: false)
    defer {
        sync.shutdown()
        if let original { defaults.set(original, forKey: iCloudSync.prefKey) }
        else { defaults.removeObject(forKey: iCloudSync.prefKey) }
    }
    return try body(sync)
}
check("OFF then ON rejects an old cloud adoption and accepts a new one") {
    try switchableSync("generation-cloud") { sync in
        let manager = LayoutManager(storageURL: file("generation-local"), sync: sync)
        manager.addProfile(fixture("local"))
        sync.syncDispatchQueue.sync {}
        deliverMainCallbacks()
        sync.mergeAndPush(localSnapshot: [fixture("remote")])
        manager.kickPush()
        sync.syncDispatchQueue.sync {}
        sync.enabled = false
        sync.enabled = true
        deliverMainCallbacks()
        guard names(manager.allProfiles) == ["local"] else { return false }
        manager.kickPush()
        sync.syncDispatchQueue.sync {}
        deliverMainCallbacks()
        return names(manager.allProfiles) == ["local", "remote"]
    }
}
check("deleting while sync is paused survives re-enabling") {
    try switchableSync("paused-delete-cloud") { sync in
        let manager = LayoutManager(storageURL: file("paused-delete-local"), sync: sync)
        let p = fixture("deleted-while-off")
        manager.addProfile(p)
        sync.syncDispatchQueue.sync {}
        deliverMainCallbacks()
        sync.enabled = false
        manager.deleteProfile(id: p.id)
        guard manager.allProfiles.first?.deletedAt != nil else { return false }
        sync.enabled = true
        manager.kickPush()
        sync.syncDispatchQueue.sync {}
        deliverMainCallbacks()
        return manager.profile(id: p.id) == nil && sync.pull()?.first?.deletedAt != nil
    }
}
check("content comparison includes geometry and is safe with duplicate IDs") {
    let p = fixture("profile")
    var changed = p
    changed.windows = [WindowSnapshot(bundleID: "test", windowTitle: "", frame: CGRect(x: 0,y: 0,width: 100,height: 100), normalizedFrame: CGRect(x: 0,y: 0,width: 0.5,height: 0.5), screenIndex: 0)]
    return !LayoutManager.sameContent([p], [changed]) && !LayoutManager.sameContent([p,p], [p,p])
}

print("Storage safety: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
