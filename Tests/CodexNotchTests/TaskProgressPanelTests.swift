import AppKit
import Foundation
import Testing
@testable import CodexNotch

@MainActor private func panelTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-progress-panel-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor private func waitForDraft(_ session: TaskProgressDocumentDraftSession) async throws {
    for _ in 0..<200 {
        if !session.busy { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.busy)
}

@Test @MainActor func taskProgressDraftKeepsEditsWhenBindingsChangeInBackground() async throws {
    let directory = try panelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = ["a.md", "b.md", "c.md"].map { directory.appendingPathComponent($0) }
    for path in paths { try "- [ ] Task\n".write(to: path, atomically: true, encoding: .utf8) }
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    let first = TaskProgressBinding(id: UUID(), path: paths[0].path, scope: .document)
    try store.replaceBindings(threadID: "thread", with: [first])
    let draft = TaskProgressDocumentDraftSession(store: store, threadID: "thread")
    defer { draft.stop() }
    draft.loadIfNeeded()
    try await waitForDraft(draft)
    draft.remove(id: first.id)
    draft.add(path: paths[1].path)
    try await waitForDraft(draft)
    let addedElsewhere = TaskProgressBinding(id: UUID(), path: paths[2].path, scope: .document)
    try store.replaceBindings(threadID: "thread", with: [first, addedElsewhere])
    draft.observeBindingRevision()
    #expect(draft.rows.map(\.path) == [paths[1].path])
    #expect(draft.conflictingRevision)
    #expect(!draft.canSave)
    #expect(draft.changes == .init(added: 1, removed: 1, scopeChanged: 0))
    draft.reload()
    try await waitForDraft(draft)
    #expect(draft.rows.map(\.path) == [paths[0].path, paths[2].path])
    #expect(!draft.conflictingRevision)
    #expect(!draft.changes.isDirty)
}

@Test @MainActor func taskProgressDraftRefreshesChangedFileBeforeConfirming() async throws {
    let directory = try panelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tasks.md")
    try "- [ ] First\n".write(to: file, atomically: true, encoding: .utf8)
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    let draft = TaskProgressDocumentDraftSession(store: store, threadID: "thread")
    defer { draft.stop() }
    draft.add(path: file.path)
    try await waitForDraft(draft)
    #expect(draft.canSave)
    try "- [x] First\n- [ ] Second\n".write(to: file, atomically: true, encoding: .utf8)
    var saved = false
    draft.save { saved = true }
    try await waitForDraft(draft)
    #expect(!saved)
    #expect(store.bindings(for: "thread").isEmpty)
    #expect(draft.rows.first?.selected?.total == 2)
    #expect(draft.rows.first?.selected?.completed == 1)
    #expect(draft.message?.contains("文档在预览后发生变化") == true)
    draft.save { saved = true }
    try await waitForDraft(draft)
    #expect(saved)
    #expect(store.bindings(for: "thread").map(\.path) == [file.path])
}

@Test @MainActor func taskProgressClearingDraftRequiresExplicitClearAndPersistsExclusion() async throws {
    let directory = try panelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tasks.md")
    try "- [ ] Task\n".write(to: file, atomically: true, encoding: .utf8)
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    try store.replaceBindings(threadID: "thread", with: [.init(id: UUID(), path: file.path, scope: .document)])
    let draft = TaskProgressDocumentDraftSession(store: store, threadID: "thread")
    defer { draft.stop() }
    draft.loadIfNeeded()
    try await waitForDraft(draft)
    draft.clear()
    #expect(draft.needsClearConsent)
    #expect(!draft.canSave)
    draft.clearConsent = true
    #expect(draft.canSave)
    var saved = false
    draft.save { saved = true }
    try await waitForDraft(draft)
    #expect(saved)
    #expect(store.bindings(for: "thread").isEmpty)
    #expect(store.ignoredPaths(for: "thread") == [file.path])
}

@Test @MainActor func taskProgressFloatingPanelPinsOutsideParentAndResetsOnClose() async throws {
    _ = NSApplication.shared
    let directory = try panelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskProgressStore(codexHome: directory.path, automatic: false,
        storageDirectory: directory.appendingPathComponent("state"), reader: .init(stabilityNanoseconds: 0))
    defer { store.stop() }
    let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
        styleMask: [.borderless], backing: .buffered, defer: false)
    owner.isReleasedWhenClosed = false
    let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 80, height: 20))
    owner.contentView?.addSubview(anchor)
    owner.orderFrontRegardless()
    defer { owner.orderOut(nil); owner.contentView = nil; owner.close() }
    let presenter = TaskProgressPanelPresenter()
    presenter.anchor = anchor
    defer { presenter.close() }
    presenter.show(store: store, threadID: "thread")
    let panel = try #require(presenter.panel)
    #expect(panel.parent === owner)
    #expect(TaskProgressFloatingPanel.contains(panel))
    presenter.setPinned(true)
    #expect(panel.parent == nil)
    #expect(presenter.isPinned)
    owner.orderOut(nil)
    #expect(panel.isVisible)
    presenter.closeIfUnpinned()
    #expect(presenter.isPresented)
    presenter.close()
    #expect(!presenter.isPinned)
    #expect(!presenter.isPresented)
    #expect(presenter.panel == nil)
    #expect(!panel.isVisible)
}

@Test @MainActor func taskProgressFloatingGeometryKeepsPanelWithinDisplay() {
    let visible = NSRect(x: -1_440, y: 30, width: 1_440, height: 870)
    for anchor in [NSRect(x: -1_435, y: 860, width: 70, height: 20),
                   NSRect(x: -75, y: 35, width: 70, height: 20),
                   NSRect(x: -600, y: 440, width: 70, height: 20)] {
        let frame = TaskProgressPanelPresenter.anchoredFrame(anchor: anchor, size: NSSize(width: 460, height: 560), visibleFrame: visible)
        #expect(visible.contains(frame))
        #expect(frame.width == 460 && frame.height == 560)
    }
}
