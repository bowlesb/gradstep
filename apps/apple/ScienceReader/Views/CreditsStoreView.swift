import StoreKit
import SwiftUI

/// Plans and the credit pack, sold through the App Store. Every purchase is
/// bound to the signed-in account and confirmed by the server before StoreKit
/// finishes it (docs/architecture/PURCHASES.md).
struct CreditsStoreView: View {
    @Bindable var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
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
                // An information sheet: Done on the right, regular weight (docs/DESIGN.md).
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
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
            Text("Credits pay for converting papers and for AI answers.")
        } actions: {
            Button {
                // Sign-in is its own sheet; it opens once this one has gone.
                dismiss()
                model.openSignIn()
            } label: {
                // The accent is light in dark mode, so the label inverts with it.
                Text("Sign in").foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
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
        VStack(alignment: .leading, spacing: 6) {
            if let balance = model.creditBalance {
                Text("\(balance.available.formatted()) credits available").font(.headline)
                    .accessibilityIdentifier("store.balance")
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
            Text("Credits pay for converting papers and for AI answers. A first question on a paper uses about 25 credits; follow-ups use fewer.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Plans renew monthly until you cancel in Settings › Apple Account › Subscriptions. Plan credits are added each month and don’t carry over; purchased credits never expire.")
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
}
