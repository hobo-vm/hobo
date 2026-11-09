import HoboAppModel
import HoboCore
import SwiftUI
import UniformTypeIdentifiers

/// The library window: VMs in a sidebar, the selected one's details and settings beside it.
struct LibraryView: View {
    @Bindable var library: LibraryWindowState
    @State private var selection: String?
    @State private var cloning: String?
    @State private var renaming: String?
    @State private var deleting: String?

    private var model: Library { library.model }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if let build = model.build {
                    BuildRow(build: build).tag(BuildRow.tag)
                }
                ForEach(model.vms, id: \.name) { vm in
                    VMRow(vm: vm, icon: model.icon(for: vm.name), busy: model.busy[vm.name])
                        .tag(vm.name)
                        .contextMenu { contextMenu(for: vm) }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .overlay {
                if model.loaded && model.vms.isEmpty && model.build == nil {
                    ContentUnavailableView {
                        Label("No VMs", systemImage: "shippingbox")
                    } description: {
                        Text("Create one with New VM, or from a Hobo.toml recipe.")
                    } actions: {
                        Button("New VM…") { library.presentNewVM = true }
                    }
                }
            }
        } detail: {
            if selection == BuildRow.tag, let build = model.build {
                BuildView(build: build) { model.dismissBuild() }
            } else if let name = selection, let vm = model.summary(named: name) {
                VMDetailView(vm: vm, model: model).id(vm.name)
            } else {
                Text("Select a VM").foregroundStyle(.secondary)
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $library.presentNewVM) {
            NewVMSheet { form in
                model.create(from: form)
                selection = BuildRow.tag
            }
        }
        .fileImporter(isPresented: $library.presentRecipePicker, allowedContentTypes: [UTType(filenameExtension: "toml") ?? .plainText]) { result in
            if case .success(let file) = result { askNameForRecipe = file }
        }
        .sheet(item: $askNameForRecipe) { file in
            NameSheet(title: "Create a VM from \(file.lastPathComponent)", action: "Create") { name in
                model.create(name, recipe: file)
                selection = BuildRow.tag
            }
        }
        .sheet(item: $cloning) { source in
            NameSheet(title: "Clone \(source)", action: "Clone", initial: "\(source)-clone") { model.clone(source, to: $0) }
        }
        .sheet(item: $renaming) { old in
            NameSheet(title: "Rename \(old)", action: "Rename", initial: old) { new in
                model.rename(old, to: new)
                selection = new
            }
        }
        .confirmationDialog(
            "Delete \(deleting ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { name in
            Button("Delete", role: .destructive) { model.delete(name, force: model.summary(named: name)?.state == .running) }
        } message: { name in
            Text(deleteMessage(name))
        }
        .alert("Hobo", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    @State private var askNameForRecipe: URL?

    private var selected: VMSummary? { selection.flatMap(model.summary(named:)) }

    private func deleteMessage(_ name: String) -> String {
        guard let vm = model.summary(named: name) else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(vm.allocatedBytes + (vm.snapshotBytes ?? 0)), countStyle: .file)
        let running = vm.state == .running ? " It is running and will be powered off." : ""
        return "Its bundle and snapshots (\(size)) are deleted.\(running) This can't be undone."
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("New VM…") { library.presentNewVM = true }
                Button("Create from Recipe…") { library.presentRecipePicker = true }
            } label: {
                Label("New VM", systemImage: "plus")
            }
        }
        ToolbarItemGroup {
            let vm = selected
            let actions = vm.map(Actions.init) ?? Actions()
            Button { vm.map { model.start($0.name) } } label: { Label("Start", systemImage: "play.fill") }
                .disabled(!actions.start)
            Button { vm.map { model.stop($0.name) } } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(!actions.stop)
            Button { vm.map { model.suspend($0.name) } } label: { Label("Suspend", systemImage: "pause.fill") }
                .disabled(!actions.stop)
            Button { vm.map { model.showWindow($0.name) } } label: { Label("Show Window", systemImage: "macwindow") }
                .disabled(!actions.stop)
            Button { cloning = vm?.name } label: { Label("Clone", systemImage: "plus.square.on.square") }
                .disabled(!actions.clone)
            Button { deleting = vm?.name } label: { Label("Delete", systemImage: "trash") }
                .disabled(!actions.delete)
        }
    }

    @ViewBuilder
    private func contextMenu(for vm: VMSummary) -> some View {
        let actions = Actions(vm)
        Button("Start") { model.start(vm.name) }.disabled(!actions.start)
        Button("Stop") { model.stop(vm.name) }.disabled(!actions.stop)
        Button("Suspend") { model.suspend(vm.name) }.disabled(!actions.stop)
        if vm.state == .suspended { Button("Discard Saved State") { model.discard(vm.name) } }
        Button("Show Window") { model.showWindow(vm.name) }.disabled(!actions.stop)
        Divider()
        Button("Rename…") { renaming = vm.name }.disabled(!actions.clone)
        Button("Clone…") { cloning = vm.name }.disabled(!actions.clone)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: vm.bundle)]) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = vm.name }.disabled(!actions.delete)
    }

    /// Which actions a VM's state allows; the core refuses the rest anyway, with its own message.
    struct Actions {
        var start = false, stop = false, clone = false, delete = false

        init() {}

        init(_ vm: VMSummary) {
            switch vm.state {
            case .stopped, .crashed: (start, clone, delete) = (true, true, true)
            case .suspended: (start, delete) = (true, true)
            case .running: (stop, delete) = (true, true)
            case .failed, .broken: delete = true
            case .building: break
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// A VM in the sidebar: its icon, name and state, as `hobo list` words it.
struct VMRow: View {
    var vm: VMSummary
    var icon: NSImage?
    var busy: String?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "shippingbox").resizable() }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name).font(.headline)
                HStack(spacing: 4) {
                    if busy != nil { ProgressView().controlSize(.mini) }
                    Text(busy.map { "\($0)…" } ?? VMState.text(vm)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A build's row, above the VMs.
struct BuildRow: View {
    static let tag = "\u{0}build"
    var build: Library.Build

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: build.failure == nil ? "hammer" : "exclamationmark.triangle")
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(build.name).font(.headline)
                Text(build.failure == nil ? "Building…" : "Build failed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A short state, the words `hobo list` uses.
enum VMState {
    static func text(_ vm: VMSummary) -> String {
        var text = switch vm.state {
        case .running:
            vm.phase.map { $0 + (vm.phaseDetail.map { " (\($0))" } ?? "") } ?? (vm.windowShown == true ? "running (window)" : "running")
        case .crashed: "crashed"
        default: vm.state.rawValue
        }
        if vm.config?.ephemeral == true { text += ", ephemeral" }
        return text
    }
}
