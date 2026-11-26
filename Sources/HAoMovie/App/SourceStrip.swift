import SwiftUI

/// A horizontal strip of selectable chips (lines, flags, source groups, episode
/// pages): the selected one is filled, a tap chooses it, and a long press shows
/// the item's actions when given.
struct SourceStrip: View {
    struct Item: Identifiable, Hashable {
        let id: String
        let name: String
        var count: Int?
        init(id: String, name: String, count: Int? = nil) {
            self.id = id
            self.name = name
            self.count = count
        }
    }

    let items: [Item]
    let selection: String
    let select: (String) -> Void
    let actions: ((String) -> AnyView)?

    init(items: [Item], selection: String, select: @escaping (String) -> Void) {
        self.items = items
        self.selection = selection
        self.select = select
        self.actions = nil
    }

    init(items: [Item], selection: String, select: @escaping (String) -> Void, actions: ((String) -> AnyView)?) {
        self.items = items
        self.selection = selection
        self.select = select
        self.actions = actions
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    Chip(title: item.name + (item.count.map { " (\($0))" } ?? ""), selected: item.id == selection) {
                        select(item.id)
                    }
                    .contextMenu {
                        if let actions {
                            actions(item.id)
                        }
                    }
                }
            }
        }
    }
}

/// An episode's file detail under its name: quality and size, in small secondary text.
struct EpisodeFileDetail: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}
