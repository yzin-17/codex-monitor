from pathlib import Path
root=Path.cwd()
p=root/'Sources/CodexNotch/HUDLayoutEditorView.swift'
s=p.read_text()
s=s.replace('    var body: some View {\n        Section("显示模式 · 即时生效") {', '''    @ViewBuilder var body: some View {
        presentationSection
        sourceSection
        layoutSection
    }
    private var presentationSection: some View {
        Section {
''',1)
s=s.replace('''        }
        Section("HUD 数据来源 · 即时生效") {''','''        } header: { Text("显示模式 · 即时生效") }
    }
    private var sourceSection: some View {
        Section {''',1)
s=s.replace('''        }
        Section("布局 · 拖动排序 / 点击添加") {''','''        } header: { Text("HUD 数据来源 · 即时生效") }
    }
    private var layoutSection: some View {
        Section {''',1)
s=s.replace('''        }
    }
    private func chip''','''        } header: { Text("布局 · 拖动排序 / 点击添加") }
    }
    private func chip''',1)
s=s.replace('Picker("面板动画", selection: $preferences.value.animation)', 'Picker("面板动画", selection: Binding(get: { preferences.value.animation }, set: { preferences.value.animation = $0 }))')
p.write_text(s)
p=root/'Sources/CodexNotch/CodexAccountsStore.swift'
s=p.read_text().replace('import Security','import Security\nimport LocalAuthentication',1)
s=s.replace('''        if !interactive { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }''','''        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }''',1)
p.write_text(s)
