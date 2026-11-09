import HoboAppModel
import HoboCore
import SwiftUI

/// New VM: what `hobo init` asks, plus the machine. The images come from the same catalogs as
/// `hobo images`, newest of each version.
struct NewVMSheet: View {
    var create: (NewVMForm) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var form = NewVMForm()
    @State private var macOSImages: [IPSWCatalog.Image] = []
    @State private var linuxImages: [UbuntuCatalog.Image] = []
    @State private var catalogProblem: String?
    @State private var pickingISO = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $form.name, prompt: Text("dev"))
                Picker("System", selection: $form.os) {
                    Text("macOS").tag(VMConfig.OS.macOS)
                    Text("Linux (Ubuntu)").tag(VMConfig.OS.linux)
                    Text("Windows 11 on Arm").tag(VMConfig.OS.windows)
                }
                source
                Section("Machine") {
                    Stepper("CPUs: \(form.cpus)", value: $form.cpus, in: 1...ProcessInfo.processInfo.processorCount)
                    Stepper("Memory: \(form.memoryGB) GB", value: $form.memoryGB, in: 1...max(1, Int(ProcessInfo.processInfo.physicalMemory >> 30)))
                    Stepper("Disk: \(form.diskGB) GB", value: $form.diskGB, in: 16...16384, step: 8)
                }
                if form.os == .macOS {
                    Section {
                        Toggle("GUI testing", isOn: $form.guiTesting)
                    } footer: {
                        Text("Lets hobo exec, hobo screenshot and hobo ui drive the guest's apps.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if let problem = form.problem, !form.name.isEmpty { Text(problem).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    create(form)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(form.problem != nil)
            }
            .padding()
        }
        .frame(width: 520)
        .task(id: form.os) { await loadCatalog() }
        .fileImporter(isPresented: $pickingISO, allowedContentTypes: [.diskImage, .data]) { result in
            if case .success(let iso) = result { form.windowsISO = iso }
        }
    }

    @ViewBuilder
    private var source: some View {
        switch form.os {
        case .macOS:
            Picker("Version", selection: $form.macOSImage) {
                Text("Latest").tag(IPSWCatalog.Image?.none)
                ForEach(macOSImages, id: \.build) { image in
                    Text("\(image.name) \(image.version) (\(image.build))").tag(Optional(image))
                }
            }
            if let catalogProblem { Text(catalogProblem).font(.caption).foregroundStyle(.secondary) }
        case .linux:
            Picker("Version", selection: $form.linuxImage) {
                if linuxImages.isEmpty { Text("Loading…").tag(UbuntuCatalog.Image?.none) }
                ForEach(linuxImages, id: \.serial) { image in
                    Text("\(image.name) \(image.version)").tag(Optional(image))
                }
            }
            Toggle("Desktop", isOn: $form.linuxDesktop)
            if let catalogProblem { Text(catalogProblem).font(.caption).foregroundStyle(.secondary) }
        case .windows:
            LabeledContent("Installer ISO") {
                HStack {
                    Text(form.windowsISO?.lastPathComponent ?? "None").foregroundStyle(.secondary)
                    Button("Choose…") { pickingISO = true }
                }
            }
            Text("Download a Windows 11 on Arm ISO from Microsoft first; there is no catalog to pick one from.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadCatalog() async {
        catalogProblem = nil
        do {
            switch form.os {
            case .macOS where macOSImages.isEmpty:
                macOSImages = IPSWCatalog.latestPerMajor(IPSWCatalog.runnable(try await IPSWCatalog.fetch(), hostMajor: IPSWCatalog.hostMajor))
            case .linux where linuxImages.isEmpty:
                let catalog = try await UbuntuCatalog.fetch()
                linuxImages = UbuntuCatalog.latestPerSeries(UbuntuCatalog.supported(catalog))
                if form.linuxImage == nil { form.linuxImage = try? UbuntuCatalog.newestLTS(in: catalog) }
            default: break
            }
        } catch {
            catalogProblem = "Couldn't load the catalog: \(error)"
        }
    }
}

/// Asks for a VM name: for Clone, Rename and Create from Recipe.
struct NameSheet: View {
    var title: String
    var action: String
    var initial = ""
    var submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var problem: String? {
        do {
            try VMStore.validate(name)
            return nil
        } catch {
            return "\(error)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
            if let problem, !name.isEmpty { Text(problem).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(action) {
                    submit(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || name == initial && action == "Rename")
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear { name = initial }
    }
}
