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
                if model.storeOwnershipKnown {
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
            .disabled(!model.canPurchase)
            .storeButton(.hidden, for: .cancellation)
            .inAppPurchaseOptions { _ in model.purchaseOptions }
            .onInAppPurchaseCompletion { _, result in
                if case .success(let outcome) = result { await model.completePurchase(outcome) }
                else { model.storeNotice = "The purchase couldn’t be completed. Try again later." }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            .navigationTitle("Get credits").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Restore") {
                        restoring = true
                        Task { await model.restorePurchases(); restoring = false }
                    }.disabled(restoring).accessibilityIdentifier("store.restore")
                }
            }
            .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
            .alert("Purchases", isPresented: Binding(get: { model.storeNotice != nil }, set: { if !$0 { model.storeNotice = nil } })) {
                Button("OK") {}
            } message: { Text(model.storeNotice ?? "") }
            .task { await model.refreshCreditBalance(); await model.syncStoreTransactions() }
        }
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
        VStack(spacing: 4) {
            Text("Plans renew monthly until you cancel in Settings › Apple Account › Subscriptions. Plan credits are added each month and don’t carry over; purchased credits never expire.")
            Link("Terms of Use", destination: Self.termsURL)
        }
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }
}
