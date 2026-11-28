import SwiftUI

/// The welcome page's recommended sources: the same verified list the Add
/// Subscription sheet offers (`RecommendedSubscriptions`, SettingsView.swift),
/// so a first-run viewer can tap one and be done instead of pasting an address.
/// No addresses are invented here and none are auto-imported: each row imports
/// only when tapped, through the same `Store.importSubscription(address:name:)`
/// the sheet uses.
struct WelcomeRecommendedSources: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Recommended Sources"))
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(RecommendedSubscriptions.all, id: \.address) { item in
                    Button {
                        Task {
                            await store.importSubscription(address: item.address, name: item.name)
                        }
                    } label: {
                        FormLabel(symbol: "star.fill", tint: Brand.amber, title: item.name, subtitle: item.detail)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .disabled(store.importing)
                }
            }
            .padding(.horizontal, 16)
            .contentPanel()
            if let error = store.importError {
                Text(error).font(.subheadline).foregroundStyle(Brand.amber)
            } else {
                Text(L10n.text("Tap one to import it — no need to paste an address."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Search with no subscription. The one-line note this replaces only said to add
/// one; Yingxia's no-subscription pages say it with a symbol, a title and a way
/// forward (LiveView.swift: the EmptyPage "Connect a Live Subscription"), and
/// this is the same shape for search.
struct SearchNeedsSubscriptionView: View {
    @Environment(Store.self) private var store

    var body: some View {
        EmptyResults(symbol: "magnifyingglass", title: L10n.text("Search Needs a Subscription"),
                     message: L10n.text("Add a subscription in Settings to search its sources."),
                     action: AppSection.settings.title, actionSymbol: AppSection.settings.icon) { store.section = .settings }
    }
}
