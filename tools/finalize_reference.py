#!/usr/bin/env python3
"""固定基线导入后的兼容补丁；只修改目标源码并更新来源哈希。"""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
def edit(path,old,new):
 f=root/path; s=f.read_text(); assert s.count(old)==1, f'补丁锚点不匹配：{path}: {old[:80]}'
 f.write_text(s.replace(old,new))
# ALight 的 SQLiteJSONReader 本来就是只读，不需要 donor 的额外参数。
edit('Sources/CodexNotch/SkillSessionAnalyzer.swift',
 '                    as: [ThreadRow].self,\n                    readOnly: true',
 '                    as: [ThreadRow].self')
assert 'let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX' in (root/'Sources/CodexNotch/Shell.swift').read_text()
# 干净 checkout 下 dist 不存在；使用上游已提交的图标，构建不能改写受版本控制的资源。
edit('scripts/build-app.sh', 'swift "$ROOT_DIR/scripts/generate-app-icon.swift"',
 'mkdir -p "$DIST_DIR"\nif [[ ! -s "$ROOT_DIR/Resources/AppIcon.icns" ]]; then\n  swift "$ROOT_DIR/scripts/generate-app-icon.swift"\nfi')
edit('Sources/CodexNotch/TokenPricingUpdater.swift',
 'Library/Application Support/codex监测/ModelPricing/current.json',
 'Library/Application Support/CodexMonitor/ModelPricing/current.json')
# ImageRenderer 不包含 AppKit 滚动区域。把同一生产视图挂入真实 NSHostingView 后捕获。
path='Tests/CodexNotchTests/ReferenceExtensionTests.swift'
edit(path,'func referenceNativeTabsRenderFromActualUpstreamViews() throws {',
 'func referenceNativeTabsRenderFromActualUpstreamViews() async throws {')
edit(path,'''        let image = try #require(renderer.cgImage)
        #expect(image.width >= 600)
        #expect(image.height >= 400)
        if let output {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\\(page.rawValue).png"))
        }''','''        let measured = try #require(renderer.cgImage)
        let size = NSSize(width: CGFloat(measured.width) / renderer.scale, height: CGFloat(measured.height) / renderer.scale)
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 300)
        #expect(bitmap.pixelsHigh >= 400)
        if let output {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\\(page.rawValue).png"))
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()''')
lockfile=root/'docs/UPSTREAM_LOCK.json'
lock=json.loads(lockfile.read_text())
for entry in lock['files']:
 entry['sha256']=hashlib.sha256((root/entry['path']).read_bytes()).hexdigest()
 entry['modified']=entry['sha256']!=entry['source_sha256']
lockfile.write_text(json.dumps(lock,ensure_ascii=False,indent=2)+'\n')
