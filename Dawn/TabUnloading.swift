import AppKit

// Gives memory back while macOS says it's short, by unloading background tabs: their pages go, kept to
// come back as they were when shown again. The tab used least recently goes first, one at a time, and
// the next only once the last one's page has actually let its memory go (its web content process has
// exited), for as long as memory stays short. Never unloaded: the tab each window shows and the one it
// showed before (switching between the two stays instant), favorites, and any page that couldn't come
// back exactly as it is (see BrowserState.checkUnloadable).
final class MemoryPressureUnloader {
    private let controllers: () -> [MainWindowController]
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    private let check = DispatchSource.makeTimerSource(queue: .main)
    private var unloading = false
    private var exitWatch: DispatchSourceProcess?

    // macOS tells processes memory is short one at a time, the largest first, and at most once per
    // pressure period, so a small app may not hear of it for a long while; the system's pressure level
    // itself is also looked at once a period. (xnu's VM_PRESSURE_NOTIFY_WAIT_PERIOD is ten seconds.)
    private static let pressurePeriod: DispatchTimeInterval = .seconds(10)

    init(controllers: @escaping () -> [MainWindowController]) {
        self.controllers = controllers
        source.setEventHandler { [weak self] in self?.unloadNext() }
        source.activate()
        check.schedule(deadline: .now() + Self.pressurePeriod, repeating: Self.pressurePeriod, leeway: Self.pressurePeriod)
        check.setEventHandler { [weak self] in self?.unloadNext() }
        check.activate()
    }

    // the system's memory pressure level, which is past normal while memory is short
    private static var memoryIsShort: Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return false }
        let normal: Int32 = 1
        return level > normal
    }

    private func unloadNext() {
        guard !unloading, Self.memoryIsShort else { return }
        unloading = true
        unloadFirstEligible(candidates()) { [weak self] unloaded, pid in
            guard let self else { return }
            self.unloading = false
            guard unloaded, let pid else { return }
            self.afterExit(of: pid) { [weak self] in self?.unloadNext() }
        }
    }

    // every eligible background tab, at once (the develop menu's way to try it)
    func unloadEverythingEligible() {
        unloadFirstEligible(candidates()) { [weak self] unloaded, _ in
            if unloaded { self?.unloadEverythingEligible() }
        }
    }

    // background pages, the one used least recently first
    private func candidates() -> [(MainWindowController, UUID)] {
        var found: [(MainWindowController, UUID, Date)] = []
        for controller in controllers() {
            for id in controller.browserStates.keys where id != controller.currentTabId && id != controller.previousTabId {
                guard let tab = controller.tab(for: id) else { continue }
                found.append((controller, id, tab.lastAccessedAt))
            }
        }
        return found.sorted { $0.2 < $1.2 }.map { ($0.0, $0.1) }
    }

    // unloads the first candidate that can go, reporting whether one went and the process that showed it
    private func unloadFirstEligible(_ candidates: [(MainWindowController, UUID)], completion: @escaping (Bool, pid_t?) -> Void) {
        guard let (controller, id) = candidates.first, let state = controller.browserStates[id] else { return completion(false, nil) }
        state.checkUnloadable { [weak self, weak controller] unloadable in
            guard let self, let controller else { return completion(false, nil) }
            guard unloadable else { return self.unloadFirstEligible(Array(candidates.dropFirst()), completion: completion) }
            controller.unload(id) { unloaded, pid in
                if unloaded { return completion(true, pid) }
                self.unloadFirstEligible(Array(candidates.dropFirst()), completion: completion)
            }
        }
    }

    // a process that's already gone counts as exited. without a process to wait on (dawn couldn't name
    // it, or another page shares it and it stays), the round ends until memory runs short again.
    private func afterExit(of pid: pid_t, _ body: @escaping () -> Void) {
        guard kill(pid, 0) == 0 else { return body() }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            self?.exitWatch?.cancel()
            self?.exitWatch = nil
            body()
        }
        exitWatch = watch
        watch.activate()
    }
}
