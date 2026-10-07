import ImageIO
import PhotosUI
import ScienceReaderCore
import SwiftUI

struct ReportComposer: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var reportID = UUID()
    @State private var note = ""
    @State private var title = ""
    @State private var photo: PhotosPickerItem?
    @State private var screenshot: UIImage?
    @State private var attachment: ReportImage?
    @State private var consent = false
    @State private var editingImage = false
    @State private var busy = false
    @State private var loadingImage = false
    @State private var photoVersion = UUID()
    @State private var pendingDraft: SupportDraft?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What happened?") {
                    TextField("Short title (optional)", text: $title)
                    TextField("Describe the issue and what you expected", text: $note, axis: .vertical).lineLimit(4...12).accessibilityIdentifier("report.note")
                }.disabled(pendingDraft != nil)
                Section("Screenshot") {
                    if let screenshot {
                        Image(uiImage: screenshot).resizable().scaledToFit().frame(maxHeight: 340).accessibilityLabel("Screenshot preview")
                        Button("Crop or redact") { editingImage = true }
                        Button("Remove screenshot", role: .destructive) { self.screenshot = nil; attachment = nil; consent = false }
                    }
                    PhotosPicker(selection: $photo, matching: .images) { Label("Attach a screenshot", systemImage: "photo") }
                    Text("Only this preview is uploaded. Crop or cover private details.").font(.footnote).foregroundStyle(.secondary)
                }.disabled(pendingDraft != nil || loadingImage)
                Section {
                    Toggle(attachment == nil ? "Share note with support" : "Share note and screenshot with support", isOn: $consent).accessibilityIdentifier("report.consent")
                    Button { Task { await send() } } label: { HStack { Text("Send report"); Spacer(); if busy { ProgressView() } } }
                        .disabled(busy || loadingImage || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !consent || model.support == nil)
                        .accessibilityIdentifier("report.send")
                    if model.support == nil { Text("Sign in before sending. You can still preview and edit your screenshot.").font(.footnote).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Support receives your note, any attached screenshot, app/OS version, and screen name. No full chat history, keys, or logs. Offline reports stay encrypted here until sent.")
                }
            }.navigationTitle("Report an issue").navigationBarTitleDisplayMode(.inline)
                .disabled(busy)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.disabled(busy).macBarButton() } }
                .onAppear { if screenshot == nil, let captured = model.reportScreenshot { prepare(captured) } }
                .onChange(of: photo) { _, item in
                    consent = false; loadingImage = true
                    let version = UUID(); photoVersion = version
                    Task {
                        defer { if photoVersion == version { loadingImage = false } }
                        do {
                            guard let bytes = try await item?.loadTransferable(type: Data.self), bytes.count <= 20 * 1024 * 1024,
                                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560] as CFDictionary) else { throw ReaderError.invalidEvent }
                            if photoVersion == version { prepare(UIImage(cgImage: thumb)) }
                        } catch { if photoVersion == version { self.error = "The image could not be opened. Choose a PNG or JPEG screenshot under 20 MB." } }
                    }
                }
                .sheet(isPresented: $editingImage) {
                    if let screenshot { ScreenshotEditor(image: screenshot) { result in self.screenshot = result.image; attachment = result.attachment; consent = false } }
                }
        }
        .interactiveDismissDisabled(busy)
        .macSheetKeys(enabled: !busy && !editingImage)
    }
    private func prepare(_ image: UIImage) {
        do { let result = try ScreenshotCapture.prepare(image); screenshot = result.image; attachment = result.attachment; consent = false; error = nil }
        catch { self.error = "This screenshot could not be prepared. You can remove it and send the note." }
    }
    private func send() async {
        guard let service = model.support else { return }
        busy = true; defer { busy = false }
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(10000))
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = pendingDraft ?? SupportDraft(id: reportID, accountID: service.accountID, reportID: reportID, action: .report, text: text,
            title: String((heading.isEmpty ? text : heading).unicodeScalars.prefix(160)),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            osVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", screen: model.reportScreen, image: attachment)
        pendingDraft = draft
        do {
            try await service.queue(draft)
            model.reportScreenshot = nil
            model.showReportsAfterComposer = true
            dismiss()
        } catch { self.error = "The report could not be saved. Keep this screen open and try again." }
    }
}

struct ScreenshotEditor: View {
    let image: UIImage
    let save: ((image: UIImage, attachment: ReportImage)) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "Cover"
    @State private var redactions: [CGRect] = []
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var active: CGRect?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Edit", selection: $mode) { Text("Cover private text").tag("Cover"); Text("Crop").tag("Crop") }.pickerStyle(.segmented)
                Text(mode == "Cover" ? "Drag to cover private details." : "Drag around the area to keep.").font(.footnote).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let factor = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                        ForEach(Array(redactions.enumerated()), id: \.offset) { _, rectangle in overlay(rectangle, size: size, crop: false) }
                        if crop != CGRect(x: 0, y: 0, width: 1, height: 1) { overlay(crop, size: size, crop: true) }
                        if let active { overlay(active, size: size, crop: mode == "Crop") }
                    }.frame(width: size.width, height: size.height).contentShape(Rectangle())
                        .accessibilityElement(children: .ignore).accessibilityLabel("Screenshot editing canvas").accessibilityIdentifier("report.editor.canvas")
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in active = rect(from: value.startLocation, to: value.location, size: size) }.onEnded { _ in
                            if let active, active.width > 0.005, active.height > 0.005 { if mode == "Crop" { crop = active } else { redactions.append(active) } }; active = nil
                        })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Reset edits") { redactions = []; crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
            }.padding().navigationTitle("Edit screenshot").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.macBarButton() }
                    ToolbarItem(placement: .topBarTrailing) { Button("Done") { do { save(try ScreenshotCapture.prepare(image, redactions: redactions, crop: crop)); dismiss() } catch { self.error = "Select a larger crop and try again." } } }
                }
        }
        .macSheetKeys()
    }
    private func overlay(_ rectangle: CGRect, size: CGSize, crop: Bool) -> some View {
        Rectangle().fill(crop ? Color.clear : .black).overlay { if crop { Rectangle().stroke(.yellow, lineWidth: 2) } }
            .frame(width: rectangle.width * size.width, height: rectangle.height * size.height).offset(x: rectangle.minX * size.width, y: rectangle.minY * size.height)
    }
    private func rect(from: CGPoint, to: CGPoint, size: CGSize) -> CGRect {
        let a = CGPoint(x: min(1, max(0, from.x / size.width)), y: min(1, max(0, from.y / size.height)))
        let b = CGPoint(x: min(1, max(0, to.x / size.width)), y: min(1, max(0, to.y / size.height)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
