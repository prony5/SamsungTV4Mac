import SwiftUI

struct DeviceListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAddSheet = false

    var body: some View {
        List(selection: $model.selectedDeviceID) {
            Section("TVs") {
                ForEach(model.devices) { device in
                    DeviceRow(device: device, isPlaying: model.playingDevice?.id == device.id)
                        .tag(device.id)
                        .contextMenu {
                            if model.isManual(device) {
                                Button("Remove", role: .destructive) { model.removeDevice(device) }
                            }
                        }
                }
            }
        }
        .overlay {
            if model.devices.isEmpty {
                if model.isScanning {
                    ProgressView("Searching for TVs…")
                } else {
                    ContentUnavailableView {
                        Label("No TVs Found", systemImage: "tv.slash")
                    } description: {
                        Text("Turn on the TV and make sure it is on the same network, or add it by IP address.")
                    } actions: {
                        Button("Add by IP…") { showAddSheet = true }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.scan() } label: {
                    Label("Search Again", systemImage: "arrow.clockwise")
                }
                .help("Search Again")
                .disabled(model.isScanning)

                Button { showAddSheet = true } label: {
                    Label("Add by IP…", systemImage: "plus")
                }
                .help("Add by IP…")
            }
        }
        .sheet(isPresented: $showAddSheet) { AddDeviceSheet() }
    }
}

private struct DeviceRow: View {
    let device: TVDevice
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isPlaying ? "play.tv.fill" : "tv")
                .font(.title2)
                .foregroundStyle(isPlaying ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .lineLimit(1)
                Text([device.model, device.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add TV by IP Address")
                .font(.headline)
            Text("You can find the IP address on the TV in Settings → General → Network → Network Status.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("192.168.0.100", text: $address)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        guard !isAdding else { return }
        isAdding = true
        error = nil
        Task {
            do {
                try await model.addDevice(address: address)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }
}
