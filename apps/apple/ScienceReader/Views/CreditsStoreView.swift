import StoreKit
import SwiftUI

/// Plans and the credit pack, sold through the App Store. Every purchase is
/// bound to the signed-in account and confirmed by the server before StoreKit
/// finishes it (docs/architecture/PURCHASES.md).
struct CreditsStoreView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var manageSubscriptions = false
    @State private var restoring = false

    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        NavigationStack {
            Group {
                // Nothing is offered until plan ownership is known, so a plan can't be
                // bought onto a subscription another account owns.
                if !model.isSignedIn {
                    signedOut
                } else if !model.canPurchase {
                    deviceNotReady
                } else if model.storeOwnershipKnown {
                    StoreView(ids: model.planOwnedElsewhere ? [StoreProducts.pack] : StoreProducts.all) { product in
                        Image(systemName: product.id == StoreProducts.pack ? "plus.circle" : product.id == StoreProducts.pro ? "sparkles" : "star")
                            .font(.title2).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    }
                    .productViewStyle(.compact)
                    .id(model.planOwnedElsewhere)
                } else {
                    ProgressView("Checking your purchases…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Restore lives in the footer, with the terms; StoreKit draws neither itself.
            .storeButton(.hidden, for: .cancellation, .restorePurchases)
            .inAppPurchaseOptions { _ in model.purchaseOptions }
            .onInAppPurchaseCompletion { _, result in
                if case .success(let outcome) = result { await model.completePurchase(outcome) }
                else { model.storeNotice = "The purchase couldn’t be completed. Try again later." }
            }
            // Until purchases can work, only the message above shows.
            .safeAreaInset(edge: .top, spacing: 0) { if model.canPurchase { header } }
            .safeAreaInset(edge: .bottom, spacing: 0) { if model.canPurchase { footer } }
            .navigationTitle("Get credits").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // An information sheet: Done on the right, like every sheet (docs/DESIGN.md).
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
            .alert("Purchases", isPresented: Binding(get: { model.storeNotice != nil }, set: { if !$0 { model.storeNotice = nil } })) {
                Button("OK") {}
            } message: { Text(model.storeNotice ?? "") }
            .task { await model.refreshCreditBalance(); await model.syncStoreTransactions() }
        }
    }

    private var signedOut: some View {
        ContentUnavailableView {
            Label("Sign in to get credits", systemImage: "creditcard")
        } description: {
            Text("Credits pay for AI answers, web searches and podcast episodes.")
        } actions: {
            Button {
                // Sign-in is its own sheet; it opens once this one has gone.
                dismiss()
                model.openSignIn()
            } label: {
                ProminentLabel(title: "Sign in")
            }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("store.signIn")
        }
    }

    /// Signed in, but this device can't buy yet: its private library is still being set up or
    /// restored (that flow presents itself; Settings shows any problem).
    private var deviceNotReady: some View {
        ContentUnavailableView("Finish setting up this device", systemImage: "creditcard",
                               description: Text("Credits can be bought once your library is set up on this device."))
    }

    private var header: some View {
        // Papers are prepared on the device for free since 2026-10-13; credits pay for answers, searches and episodes.
        let chatCapacity = model.creditBalance.map { capacity($0.available, divisor: 12, unit: "typical chat") }
        let episodeCapacity = model.creditBalance.map { capacity($0.available, divisor: 60, unit: "five-minute private episode") }
        let chat = chatCapacity ?? "less than one typical chat"
        let episode = episodeCapacity ?? "less than one five-minute private episode"
        return VStack(alignment: .leading, spacing: 6) {
            if let balance = model.creditBalance {
                Text("\(balance.available.formatted()) credits available").font(.headline)
                    .accessibilityIdentifier("store.balance")
                Text("At this balance: \(chat) or \(episode) if you used credits for one kind of work. Reading papers is free; these uses share the same balance.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.planOwnedElsewhere {
                Text("The plan on this Apple Account belongs to another account. Credit packs can still be bought here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let plan = model.storeSummary?.planName {
                HStack {
                    Text("\(plan) plan").foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage") { manageSubscriptions = true }.font(.subheadline)
                }
            }
            Text("Credits pay for paper conversion and AI answers. Usage depends on paper length and the answer.")
                .font(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                CreditUsageView()
            } label: {
                Label("How credits are used", systemImage: "questionmark.circle")
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Plans renew monthly until you cancel in \(subscriptionSettingsPath). Plan credits are added each month and don’t carry over; purchased credits never expire.")
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button(restoring ? "Restoring…" : "Restore purchases") {
                    restoring = true
                    Task { await model.restorePurchases(); restoring = false }
                }
                .disabled(restoring).accessibilityIdentifier("store.restore")
                Link("Terms of Use", destination: Self.termsURL)
            }
            .tint(Color.accentColor)
        }
        .font(.footnote).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }

    private var subscriptionSettingsPath: String {
        #if targetEnvironment(macCatalyst)
        "System Settings › Apple Account › Subscriptions"
        #else
        "Settings › Apple Account › Subscriptions"
        #endif
    }

    private func capacity(_ credits: Int64, divisor: Int64, unit: String) -> String {
        let count = credits / divisor
        return count > 0 ? "about \(count.formatted()) \(unit)\(count == 1 ? "" : "s")" : "less than one \(unit)"
    }
}

/// The short cost guide shown beside the StoreKit offers. Keep this practical and separate from
/// the longer privacy/provider explanation in About so a user can decide whether an action fits
/// their allowance before buying anything.
private struct CreditUsageView: View {
    var body: some View {
        Form {
            Section {
                Text("Credits are a flexible usage allowance. Different actions share the same balance, so the exact number of answers depends on paper length, model, effort, answer length and searches.")
            } header: { Text("The useful rule") }
            Section {
                LabeledContent("Chat", value: "Usually 4–24 credits")
                LabeledContent("Web search", value: "About 1–2 credits / search")
            } header: { Text("Typical costs") } footer: {
                Text("The chat composer shows the estimate and maximum for the selected profile before you send.")
            }
            Section {
                Text("Shared episodes in Listen use no generation credits. Recent five-minute private episodes used about 55–60 credits. A private quote can hold up to 150 credits as a safety maximum; the actual measured usage is charged and the rest is released.")
                Text("If an episode fails its quality checks, no customer credits are charged. Short, 10-minute and 20-minute profiles have their own maximums shown before you start.")
            } header: { Text("Podcasts") }
            Section {
                Text("Standard includes 800 credits and Pro includes 1,800. A light mix of new papers and chats leaves room for occasional audio; many long papers, deep answers or private episodes use the balance faster.")
                Text("You can read and play ready shared episodes without generating them. Eligible shared paper preparation can also avoid repeating Mathpix work.")
            } header: { Text("Plans and sharing") }
            Section {
                Text("Before paid work starts, Gradstep reserves a bounded maximum. When it finishes, it settles measured provider usage. A failed or interrupted action does not silently spend more than its disclosed limit.")
            } header: { Text("Why a maximum can be higher") }
        }
        .font(.subheadline)
        .navigationTitle("How credits are used")
        .navigationBarTitleDisplayMode(.inline)
    }
}
