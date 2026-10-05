import AppKit
import SwiftUI

@main
struct IELTSPracticeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 680)
        }
        .windowStyle(.titleBar)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingPhone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("IELTS Speaking Practice")
                        .font(.largeTitle.bold())
                    Text("画面の質問を読み取り、確認してから模範回答を生成します")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("回答モード", selection: $model.responseMode) {
                    ForEach(ResponseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .disabled(model.isBusy)
                Button {
                    if model.phoneServer.isRunning {
                        showingPhone = true
                    } else {
                        model.startPhoneControl()
                    }
                } label: {
                    Label(model.phoneServer.isRunning ? "QRコードを表示" : "iPhoneから操作", systemImage: "iphone")
                }
            }

            HStack(spacing: 12) {
                Button {
                    model.selectQuestionRegion()
                } label: {
                    Label(model.region == nil ? "質問の範囲を指定" : "範囲を変更", systemImage: "crop")
                }
                .disabled(model.isBusy)

                Button {
                    model.readQuestion()
                } label: {
                    Label("次の質問を読む", systemImage: "text.viewfinder")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.isBusy || model.region == nil)

            }

            HStack(spacing: 8) {
                Circle()
                    .fill((model.isBusy || model.isCheckingOllama) ? Color.orange : (model.hasOllama ? Color.green : Color.gray))
                    .frame(width: 8, height: 8)
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.region != nil {
                    Label("前回の範囲を記憶中", systemImage: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isCheckingOllama { ProgressView().controlSize(.small) }
                if !model.hasOllama {
                    Button("Ollamaを再確認") { model.checkOllama() }
                        .disabled(model.isCheckingOllama)
                        .controlSize(.small)
                }
                Spacer()
                if model.phoneServer.isRunning, let address = model.phoneServer.phoneURL {
                    Text(address)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("読み取った質問（必要なら修正してください）") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.question)
                        .font(.system(size: 16))
                        .frame(minHeight: 105, maxHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Text("質問文を確認してから生成してください。画面の監視は自動では行いません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.generateAnswer()
                        } label: {
                            Label(model.responseMode == .ieltsEnglish ? "OK・回答を生成" : "OK・答えと解説", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.responseMode.answerTitle)
                            .font(.headline)
                        Spacer()
                        if model.isGenerating {
                            ProgressView()
                                .controlSize(.small)
                            Text("生成中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !model.answer.isEmpty {
                            Text(model.answerMetric)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    ScrollView {
                        Text(model.answer.isEmpty ? (model.responseMode == .ieltsEnglish ? "C1レベルの英語回答がここに順次表示されます。" : "正解と解説がここに順次表示されます。") : model.answer)
                            .font(.system(size: 16))
                            .foregroundStyle(model.answer.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                    .frame(minHeight: 230)
                }
            }

            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if model.screenPermissionMissing {
                        Button("画面収録の設定を開く") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .onOpenURL { model.handleAutomationURL($0) }
        .onChange(of: model.phoneServer.isRunning) { _, running in
            if running { showingPhone = true }
        }
        .sheet(isPresented: $model.showRegionPicker) {
            if let image = model.regionPreview {
                RegionPickerView(image: image, initialRegion: model.region) { newRegion in
                    model.setRegion(newRegion)
                }
                .frame(minWidth: 700, minHeight: 500)
            }
        }
        .sheet(isPresented: $showingPhone) {
            PhoneControlView(server: model.phoneServer, onStop: model.stopPhoneControl)
                .frame(width: 420, height: 520)
        }
    }
}

struct RegionPickerView: View {
    let image: NSImage
    let initialRegion: CGRect?
    let onSave: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: CGRect?

    var body: some View {
        VStack(spacing: 12) {
            Text("質問が表示される部分をドラッグして囲んでください")
                .font(.headline)
            GeometryReader { geometry in
                let imageSize = image.size
                let scale = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
                let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                    SelectionCanvas(selection: $selection)
                        .frame(width: fitted.width, height: fitted.height)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .padding(.horizontal, 14)

            HStack {
                Text(selection == nil ? "範囲を選択してください" : "この範囲を保存すると、次回以降も使えます")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("この範囲を保存") {
                    guard let selection else { return }
                    onSave(selection)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 16)
        .onAppear { selection = initialRegion }
    }
}

private struct SelectionCanvas: NSViewRepresentable {
    @Binding var selection: CGRect?

    func makeNSView(context: Context) -> RegionSelectionNSView {
        let view = RegionSelectionNSView()
        view.selection = selection
        view.onSelection = { selection = $0 }
        return view
    }

    func updateNSView(_ view: RegionSelectionNSView, context: Context) {
        view.onSelection = { selection = $0 }
        if !view.isDragging { view.selection = selection }
    }
}

private final class RegionSelectionNSView: NSView {
    var selection: CGRect? { didSet { needsDisplay = true } }
    var onSelection: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private(set) var isDragging = false

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        dragStart = point
        isDragging = true
        updateSelection(to: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        updateSelection(to: clamped(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        updateSelection(to: clamped(convert(event.locationInWindow, from: nil)))
        isDragging = false
        dragStart = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let selection, bounds.width > 0, bounds.height > 0 else { return }
        let rect = CGRect(x: selection.minX * bounds.width,
                          y: selection.minY * bounds.height,
                          width: selection.width * bounds.width,
                          height: selection.height * bounds.height)
        NSColor.systemBlue.withAlphaComponent(0.14).setFill()
        NSBezierPath(rect: rect).fill()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 2
        NSColor.systemBlue.setStroke()
        outline.stroke()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func updateSelection(to point: CGPoint) {
        guard let dragStart, bounds.width > 0, bounds.height > 0 else { return }
        let rect = CGRect(x: min(dragStart.x, point.x),
                          y: min(dragStart.y, point.y),
                          width: abs(point.x - dragStart.x),
                          height: abs(point.y - dragStart.y))
        let normalized = CGRect(x: rect.minX / bounds.width,
                                y: rect.minY / bounds.height,
                                width: rect.width / bounds.width,
                                height: rect.height / bounds.height)
        selection = normalized
        onSelection?(normalized)
    }
}

struct PhoneControlView: View {
    @ObservedObject var server: PhoneServer
    let onStop: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("iPhoneから操作")
                    .font(.title2.bold())
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let qr = server.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
            } else if server.isRunning {
                Text("QRコードを作成できませんでした。下のアドレスをiPhoneで開いてください。")
                    .foregroundStyle(.orange)
            }
            if let url = server.phoneURL {
                Text(url)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            Text("同じWi-Fiに接続したiPhoneでQRコードを読み取ってください。ページから質問の読み取りと回答生成を操作できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if !server.isRunning {
                Text("サーバーを起動しています。しばらくお待ちください。")
                    .foregroundStyle(.orange)
            }
            Button("iPhone操作を停止") {
                onStop()
                dismiss()
            }
            .disabled(!server.isRunning)
            Spacer()
        }
        .padding(22)
    }
}
