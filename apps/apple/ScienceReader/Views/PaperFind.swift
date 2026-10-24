import SwiftUI
import WebKit

/// Text ranges live only in the current verified page. No DOM text or selection is mutated.
@MainActor @Observable final class PaperFindController {
    struct Match: Identifiable, Decodable { let index: Int; let text: String; var id: Int { index } }
    private struct Result: Decodable { let count: Int; let index: Int; let matches: [Match] }
    var isPresented = false
    var showsMatches = false
    var query = ""
    /// False when the bar opens already searching (from a Library search result): the keyboard stays down.
    @ObservationIgnored var focusesOnOpen = true
    private(set) var matches: [Match] = []
    private(set) var index = -1
    private weak var web: WKWebView?
    private var generation = UUID()

    func open(in web: WKWebView) { self.web = web; isPresented = true }
    func close() {
        generation = UUID(); isPresented = false; showsMatches = false; matches = []; index = -1; query = ""
        web?.callAsyncJavaScript("window.__scienceReaderFindClear?.();", arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        web?.endEditing(true)
    }
    func search() async {
        let text = query
        do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
        guard isPresented, query == text else { return }
        await run("first")
    }
    func step(_ backwards: Bool) { Task { await run(backwards ? "previous" : "next") } }
    func select(_ index: Int) { showsMatches = false; Task { await run(index) } }
    private func run(_ direction: Any) async {
        guard isPresented, let web else { return }
        let request = UUID(); generation = request
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                web.callAsyncJavaScript("return window.__scienceReaderFind?.(query, direction);",
                    arguments: ["query": String(query.prefix(200)), "direction": direction], in: nil, in: .defaultClient) { response in
                        switch response {
                        case .success(let value):
                            guard JSONSerialization.isValidJSONObject(value) else { continuation.resume(throwing: CocoaError(.coderInvalidValue)); return }
                            do { continuation.resume(returning: try JSONSerialization.data(withJSONObject: value)) }
                            catch { continuation.resume(throwing: error) }
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
            }
            guard generation == request, isPresented, let result = try? JSONDecoder().decode(Result.self, from: data),
                  result.count >= 0, result.count <= 1000, result.matches.count == result.count else { return }
            matches = result.matches; index = result.index
        } catch { if generation == request { matches = []; index = -1 } }
    }
}

struct PaperFindBar: View {
    @Bindable var find: PaperFindController
    /// Wide: a glass card floating over the top of the page instead of a bar that pushes it down.
    var floating = false
    @FocusState private var focused: Bool
    var body: some View {
        if floating {
            content.padding(.top, 8).padding(.bottom, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(uiColor: .separator), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("Find in paper", text: $find.query).textFieldStyle(.roundedBorder)
                    .focused($focused).submitLabel(.search).onSubmit { focused = false; find.step(false) }
                    .accessibilityIdentifier("paper.find.input")
                Button { focused = false; find.close() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close find").accessibilityIdentifier("paper.find.close")
                    .frame(minWidth: 44, minHeight: 44)
            }
            HStack(spacing: 12) {
                Text(find.query.isEmpty ? "" : find.matches.isEmpty ? "No matches" : "\(find.index + 1) of \(find.matches.count)\(find.matches.count == 1000 ? "+" : "")")
                    .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("paper.find.count")
                Spacer()
                Button { focused = false; find.showsMatches = true } label: { Image(systemName: "list.bullet.rectangle") }
                    .accessibilityLabel("List occurrences").accessibilityIdentifier("paper.find.matches")
                Button { focused = false; find.step(true) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
                Button { focused = false; find.step(false) } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
            }
            .buttonStyle(.plain).disabled(find.matches.isEmpty).frame(minHeight: 36)
        }
        .padding(.horizontal, 16).padding(.bottom, 6).background(floating ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
        .task { if find.focusesOnOpen { focused = true }; find.focusesOnOpen = true }
        .task(id: find.query) { await find.search() }
        .slotSheet(isPresented: $find.showsMatches) {
            NavigationStack {
                List(find.matches) { match in
                    Button { find.select(match.index) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(match.index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            Text(match.text).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("paper.find.match.\(match.index)")
                }.navigationTitle("Occurrences")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { SheetCloseButton { find.showsMatches = false } } }
            }.macSheetKeys()
        }
    }
}
