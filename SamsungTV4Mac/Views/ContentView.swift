import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            DeviceListView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            PlayerView()
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.scan() }
    }
}
