import AppKit
import SwiftUI
import CodexMonitorCore

@MainActor
final class HUDController {
    private var panel: NSPanel?
    func toggle(store:AppStore) {
        if let panel { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }; return }
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:560,height:62),
                            styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:HUDView(store:store))
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        panel.setFrameOrigin(NSPoint(x:frame.midX - 280,y:frame.maxY - 74))
        self.panel = panel; panel.orderFrontRegardless()
    }
}
private struct HUDView:View {
    @ObservedObject var store:AppStore
    var body:some View {
        HStack(spacing:18) {
            Image(systemName:"chart.bar.xaxis").foregroundStyle(.blue).font(.title3)
            VStack(alignment:.leading,spacing:3) {
                Text("Codex Monitor").font(.system(size:11,weight:.semibold))
                Text(store.demo ? "演示数据" : "\(store.window.rawValue) · 本机汇总").font(.system(size:10)).foregroundStyle(.secondary)
            }
            Divider().frame(height:26)
            Text(Display.tokens(store.usage.total)).font(.system(size:22,weight:.semibold,design:.rounded)).monospacedDigit()
            Spacer()
            if store.scanning { ProgressView().controlSize(.small) }
            else if store.snapshot.progress.pendingFiles > 0 { Text("回填中").font(.caption).foregroundStyle(.orange) }
            Button { store.refresh() } label:{Image(systemName:"arrow.clockwise")}.buttonStyle(.plain).disabled(store.scanning)
            Button { store.hud.toggle(store:store) } label:{Image(systemName:"xmark")}.buttonStyle(.plain)
        }.padding(.horizontal,20).frame(height:62).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
            .overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(0.09)))
    }
}
