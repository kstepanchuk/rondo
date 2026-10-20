import SwiftUI

/// Optional section in Settings: quality, keys and the wheel layout.
struct AdvancedSection: View {
    @ObservedObject private var a = AdvancedPrefs.shared
    @State private var editingLayout = false
    @State private var arenaPort = Arena.port

    var body: some View {
        Section {
            Toggle(L("Расширенные настройки", "Advanced settings"), isOn: $a.enabled)
            if a.enabled {
                HStack {
                    Text(L("Качество JPG/HEIC", "JPG/HEIC quality"))
                    Slider(value: $a.imageQuality, in: 0.5...1, step: 0.05)
                    Text("\(Int(a.imageQuality * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Picker(L("«Для веба»: длинная сторона", "Web-ready: long side"), selection: $a.webMaxSize) {
                    Text("1280 px").tag(1280); Text("2048 px").tag(2048); Text("3840 px").tag(3840)
                }
                Picker(L("Качество видео", "Video quality"), selection: $a.videoQuality) {
                    Text(L("Высокое", "High")).tag(VideoQuality.high)
                    Text(L("Среднее", "Medium")).tag(VideoQuality.medium)
                    Text(L("Компактное", "Compact")).tag(VideoQuality.compact)
                }
                keyPicker(L("Конвертация", "Convert"), $a.keyConvert)
                keyPicker(L("Инструменты", "Tools"), $a.keyTools)
                keyPicker(L("Действия", "Actions"), $a.keyActions)
                if Set([a.keyConvert, a.keyTools, a.keyActions]).count < 3 {
                    Text(L("Клавиши повторяются: сработает первый режим из списка.",
                           "Keys overlap: the first matching mode wins."))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(L("Порт Resolume Arena", "Resolume Arena port"))
                    Spacer()
                    TextField("8080", value: $arenaPort, format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                        .onChange(of: arenaPort) { Arena.port = $0 }
                }
                HStack {
                    Button(L("Настроить колесо…", "Customize wheel…")) { editingLayout = true }
                    Spacer()
                    Button(L("Сбросить раскладку", "Reset layout")) { a.resetLayout() }
                }
            }
        } footer: {
            if !a.enabled {
                Text(L("Качество, клавиши, порядок и скрытие секторов.", "Quality, keys, sector order and visibility."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $editingLayout) { LayoutEditor().frame(width: 420, height: 480) }
    }

    private func keyPicker(_ title: String, _ binding: Binding<ModKey>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ModKey.allCases) { Text($0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct OpRow: Identifiable { let id: String; let title: String; let symbol: String }

/// Reorder (drag) and hide sectors for one file type and mode.
struct LayoutEditor: View {
    @ObservedObject private var a = AdvancedPrefs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .image
    @State private var mode: Mode = .convert
    @State private var rows: [OpRow] = []

    private let kinds: [(Kind, String)] = [
        (.image, L("Изображения", "Images")), (.raw, "RAW"), (.video, L("Видео", "Video")),
        (.audio, L("Аудио", "Audio")), (.pdf, "PDF"), (.document, L("Документы", "Documents")),
        (.spreadsheet, L("Таблицы", "Spreadsheets")), (.presentation, L("Презентации", "Slides")),
        (.archive, L("Архивы", "Archives")), (.folder, L("Папки", "Folders")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $kind) { ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden()
                Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented)
            }
            Text(L("Перетаскивайте строки, чтобы менять порядок. Флажок — показывать сектор.",
                   "Drag rows to reorder. Checkbox shows or hides the sector."))
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(rows) { r in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { !a.hidden.contains(r.id) },
                            set: { on in if on { a.hidden.remove(r.id) } else { a.hidden.insert(r.id) } }))
                            .labelsHidden()
                        Image(systemName: r.symbol).frame(width: 20)
                        Text(r.title)
                    }
                }
                .onMove { from, to in
                    rows.move(fromOffsets: from, toOffset: to)
                    a.order[Catalog.layoutKey(kind, mode)] = rows.map(\.id)
                }
            }
            HStack { Spacer(); Button(L("Готово", "Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        .onAppear(perform: load)
        .onChange(of: kind) { _ in load() }
        .onChange(of: mode) { _ in load() }
    }

    private func load() {
        var ops = Catalog.allOperations(kind, mode)
        if let order = a.order[Catalog.layoutKey(kind, mode)] {
            let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            ops = ops.enumerated().sorted { (rank[$0.element.id] ?? 1000 + $0.offset) < (rank[$1.element.id] ?? 1000 + $1.offset) }
                .map(\.element)
        }
        rows = ops.map { OpRow(id: $0.id, title: $0.title, symbol: $0.symbol) }
    }
}
