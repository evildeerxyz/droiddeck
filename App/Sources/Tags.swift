import SwiftUI
import AppKit
import DroidDeckKit

// Colored device tags, shared across devices like Finder tags.

extension DeviceTag.Color {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: Color(red: 0.0, green: 0.52, blue: 0.58)   // darker than system teal, distinct from mint
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: Color(red: 0.95, green: 0.4, blue: 0.72)   // system pink reads as red next to .red
        case .brown: .brown
        case .gray: .gray
        }
    }

    var displayName: String { rawValue.capitalized }

    /// Menus render SF Symbols as monochrome templates, so menu items get a real colored dot.
    var menuDot: Image {
        let nsColor = NSColor(color)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

struct TagChip: View {
    let tag: DeviceTag
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tag.color.color).frame(width: 7, height: 7)
            Text(tag.name).font(.caption.weight(.medium)).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the tag \"\(tag.name)\"")
                .accessibilityLabel("Remove tag \(tag.name)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tag.color.color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(tag.color.color.opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag \(tag.name)")
    }
}

/// Tags for a table cell: as many whole chips as fit, then "+N"; colored dots when space is tight.
struct TagChips: View {
    let tags: [DeviceTag]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showing: tags.count)
            if tags.count > 2 { row(showing: 2) }
            if tags.count > 1 { row(showing: 1) }
            HStack(spacing: 3) {
                ForEach(tags) { Circle().fill($0.color.color).frame(width: 8, height: 8) }
            }
        }
        .help(tags.map(\.name).joined(separator: ", "))
    }

    private func row(showing count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(count)) { TagChip(tag: $0).fixedSize() }
            if tags.count > count {
                Text("+\(tags.count - count)").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// Lays out children left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct TagColorPicker: View {
    @Binding var selection: DeviceTag.Color

    var body: some View {
        HStack(spacing: 8) {
            ForEach(DeviceTag.Color.allCases, id: \.self) { color in
                Button { selection = color } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selection == color ? 0.85 : 0), lineWidth: 2).padding(-3))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.displayName)
                .accessibilityLabel(color.displayName)
                .accessibilityAddTraits(selection == color ? .isSelected : [])
            }
        }
        .padding(3)
    }
}

/// Names a new tag, picks its color and adds it to the given devices.
struct NewTagSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceIDs: [String]
    @State private var name = ""
    @State private var color: DeviceTag.Color = .blue

    private var existing: DeviceTag? {
        let key = DeviceTag.key(name)
        return key.isEmpty ? nil : model.devices.allTags.first { $0.id == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.headline)
            TextField("Name, e.g. Main account", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            if let existing {
                Label("\"\(existing.name)\" already exists, so it keeps its \(existing.color.displayName.lowercased()) color.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TagColorPicker(selection: $color)
            }
            Text(deviceIDs.count == 1 ? "Added to this device." : "Added to \(deviceIDs.count) devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Tag", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(DeviceTag.clean(name).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        let tag = DeviceTag(name: name, color: existing?.color ?? color)
        guard !tag.name.isEmpty else { return }
        model.devices.addTag(tag, to: deviceIDs)
        dismiss()
    }
}

/// The tags all given devices share (removable) and a menu to add more.
struct TagEditor: View {
    @Environment(AppModel.self) private var model
    let deviceIDs: [String]
    @State private var creating = false

    var body: some View {
        let devices = deviceIDs.compactMap { model.devices.device(named: $0) }
        let shared = (devices.first?.metadata.tags ?? []).filter { tag in
            devices.allSatisfy { device in device.metadata.tags.contains { $0.id == tag.id } }
        }
        let addable = model.devices.allTags.filter { tag in !shared.contains { $0.id == tag.id } }
        VStack(alignment: .leading, spacing: 8) {
            if shared.isEmpty {
                Text(devices.count > 1 ? "No tags shared by all selected devices" : "No tags")
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(shared) { tag in
                        TagChip(tag: tag) { model.devices.removeTag(tag.id, from: deviceIDs) }
                    }
                }
            }
            Menu {
                ForEach(addable) { tag in
                    Button { model.devices.addTag(tag, to: deviceIDs) } label: {
                        Label { Text(tag.name) } icon: { tag.color.menuDot }
                    }
                }
                if !addable.isEmpty { Divider() }
                Button("New Tag…") { creating = true }
            } label: {
                Label("Add Tag", systemImage: "tag")
            }
            .fixedSize()
        }
        .sheet(isPresented: $creating) { NewTagSheet(deviceIDs: deviceIDs) }
    }
}

/// Context-menu submenu: check or uncheck tags on the selected devices.
struct TagToggleMenu: View {
    @Environment(AppModel.self) private var model
    let deviceIDs: [String]
    let onNewTag: () -> Void

    var body: some View {
        let devices = deviceIDs.compactMap { model.devices.device(named: $0) }
        let library = model.devices.allTags
        Menu("Tags") {
            ForEach(library) { tag in
                let onAll = !devices.isEmpty && devices.allSatisfy { device in device.metadata.tags.contains { $0.id == tag.id } }
                Toggle(isOn: Binding(get: { onAll }, set: { add in
                    add ? model.devices.addTag(tag, to: deviceIDs) : model.devices.removeTag(tag.id, from: deviceIDs)
                })) {
                    Label { Text(tag.name) } icon: { tag.color.menuDot }
                }
            }
            if !library.isEmpty { Divider() }
            Button("New Tag…", action: onNewTag)
        }
    }
}

/// A tag's menu: recolor, rename or delete it everywhere.
struct TagManagementMenu: View {
    @Environment(AppModel.self) private var model
    let tag: DeviceTag

    var body: some View {
        Menu("Color") {
            ForEach(DeviceTag.Color.allCases, id: \.self) { color in
                Toggle(isOn: Binding(get: { tag.color == color }, set: { _ in model.devices.updateTag(tag.id, color: color) })) {
                    Label { Text(color.displayName) } icon: { color.menuDot }
                }
            }
        }
        Button("Rename…") { renameTag(tag, model: model) }
        Divider()
        Button("Delete Tag…") { deleteTag(tag, model: model) }
    }
}

@MainActor
func renameTag(_ tag: DeviceTag, model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Rename Tag"
    alert.informativeText = "The new name applies to every device with this tag."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = tag.name
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = DeviceTag.clean(field.stringValue)
    guard !name.isEmpty, name != tag.name else { return }
    let wasShown = model.tagFilter == tag.id
    model.devices.updateTag(tag.id, name: name)
    if wasShown { model.tagFilter = DeviceTag.key(name) }
}

@MainActor
func deleteTag(_ tag: DeviceTag, model: AppModel) {
    let count = model.devices.devices(taggedWith: tag.id).count
    let alert = NSAlert()
    alert.messageText = "Delete the tag \"\(tag.name)\"?"
    alert.informativeText = "It's removed from \(count == 1 ? "1 device" : "\(count) devices"). The devices themselves aren't changed."
    alert.addButton(withTitle: "Delete Tag")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    if model.tagFilter == tag.id { model.tagFilter = nil }
    model.devices.deleteTag(tag.id)
}
