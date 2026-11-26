import SwiftUI
import AppKit

struct TabBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            TabStripView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().frame(height: 16)

            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .appToolTip("Новый запрос (⌘T)")
            .padding(.horizontal, 7)

            Button {
                model.openQuickOpen()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .appToolTip("Найти запрос (⌘E)")
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(.bar)
    }
}

struct ScriptConnectionPicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.profiles) { p in
                Button {
                    model.setActiveScriptProfile(p.id)
                } label: {
                    Label {
                        Text(p.displayName)
                    } icon: {
                        Image(nsImage: DBIcon.image(for: p.kind, size: 14))
                    }
                }
            }
            if model.profiles.isEmpty {
                Text("Нет подключений")
            }
        } label: {
            HStack(spacing: 4) {
                if let p = model.activeScriptProfile {
                    Image(nsImage: DBIcon.image(for: p.kind, size: 12))
                    Text(p.displayName).lineLimit(1)
                } else {
                    Image(systemName: "cylinder.split.1x2")
                    Text("Подключение").lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: 170, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .appToolTip("Подключение для текущего скрипта")
        .padding(.trailing, 4)
    }
}
