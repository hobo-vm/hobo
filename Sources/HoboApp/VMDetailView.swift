import HoboAppModel
import HoboCore
import HoboVM
import SwiftUI

/// One VM: what `hobo list -v` says about it, and the settings `hobo set` changes.
struct VMDetailView: View {
    var vm: VMSummary
    var model: Library
    @State private var form: SettingsForm?

    var body: some View {
        Form {
            Section {
                LabeledContent("State", value: stateText(vm))
                if let config = vm.config {
                    LabeledContent("OS", value: config.osDescription)
                    LabeledContent("Created", value: config.created.formatted(date: .abbreviated, time: .shortened))
                }
                if let address = vm.ipAddress { LabeledContent("Address") { Text(address).textSelection(.enabled) } }
                LabeledContent("Disk used", value: fileSize(vm.allocatedBytes))
                if let snapshots = vm.snapshots, !snapshots.isEmpty {
                    LabeledContent("Snapshots", value: "\(snapshots.count) (\(fileSize(vm.snapshotBytes ?? 0)))")
                }
                if let saved = vm.savedStateBytes { LabeledContent("Saved state", value: fileSize(saved)) }
                LabeledContent("Bundle") { Text(vm.bundle).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            } header: {
                header
            }
            if let config = vm.config, let form = Binding($form) {
                settings(config, form: form)
            }
        }
        .formStyle(.grouped)
        .onAppear { resetForm() }
        .onChange(of: vm.config) { resetForm() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon = model.icon(for: vm.name) { Image(nsImage: icon).resizable().frame(width: 64, height: 64) }
            Text(vm.name).font(.largeTitle.bold())
        }
        .padding(.bottom, 8)
    }

    private func resetForm() { form = vm.config.map(SettingsForm.init) }

    @ViewBuilder
    private func settings(_ config: VMConfig, form: Binding<SettingsForm>) -> some View {
        let editable = SettingsForm.editable(vm)
        let limits = VMSettings.Limits.host
        let memoryMax = Int(limits.memory.upperBound >> 30)
        Section {
            Stepper("CPUs: \(form.wrappedValue.cpus)", value: form.cpus, in: limits.cpus)
            Stepper("Memory: \(form.wrappedValue.memoryGB) GB", value: form.memoryGB, in: 1...max(1, memoryMax))
            Stepper("Disk: \(form.wrappedValue.diskGB) GB", value: form.diskGB, in: SettingsForm(config).diskGB...16384, step: 8)
            SharesEditor(shares: form.shares)
        } header: {
            Text("Settings")
        } footer: {
            if let reason = editable.reason { Text(reason).foregroundStyle(.secondary) }
            else if form.wrappedValue.diskGB > SettingsForm(config).diskGB { Text("The disk only grows. The guest grows into the new space at its next start.").foregroundStyle(.secondary) }
        }
        .disabled(!editable.machine)
        if config.ephemeral {
            Section {
                Toggle("Keep this VM when it stops", isOn: form.keep)
            } footer: {
                Text("It is ephemeral: it is deleted when it stops.").foregroundStyle(.secondary)
            }
            .disabled(!editable.keep)
        }
        let changes = form.wrappedValue.settings(from: config)
        Section {
            HStack {
                Spacer()
                Button("Revert") { resetForm() }.disabled(changes.isEmpty)
                Button("Save") { model.apply(form.wrappedValue, to: vm.name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty || model.busy[vm.name] != nil)
            }
        }
    }
}

/// The shared folders: each with its guest name and read-only switch, plus Add and Remove.
struct SharesEditor: View {
    @Binding var shares: [VMShare]
    @State private var picking = false

    var body: some View {
        LabeledContent("Shared folders") {
            VStack(alignment: .trailing) {
                ForEach($shares, id: \.name) { $share in
                    HStack {
                        Text(share.path).lineLimit(1).truncationMode(.middle).help(share.path)
                        Toggle("Read-only", isOn: $share.readOnly).toggleStyle(.checkbox)
                        Button { shares.removeAll { $0.name == share.name } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { picking = true }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result,
                  let share = try? VMShare.parse(folder.path, currentDirectory: URL(filePath: "/")) else { return }
            shares.append(share)
        }
    }
}

func fileSize(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

/// A build's progress: its log as it goes, and its error if it fails.
struct BuildView: View {
    var build: Library.Build
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Building \(build.name)").font(.title2.bold())
                if !build.finished { ProgressView().controlSize(.small) }
                Spacer()
                if build.failure != nil { Button("Dismiss", action: dismiss) }
            }
            if let failure = build.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(build.log.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: build.log.count) { proxy.scrollTo(build.log.count - 1, anchor: .bottom) }
            }
            .padding(8)
            .background(.background.secondary, in: .rect(cornerRadius: 6))
            if !build.finished {
                Text("Quitting Hobo cancels the build and deletes the VM.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
