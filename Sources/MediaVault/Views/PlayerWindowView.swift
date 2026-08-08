import SwiftUI

struct PlayerWindowView: View {
    @EnvironmentObject var store: SourceStore

    var body: some View {
        PlayerWebView(store: store)
            .ignoresSafeArea()
            .frame(minWidth: 900, minHeight: 600)
    }
}
