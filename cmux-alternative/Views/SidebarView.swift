import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: TerminalSessionStore
    @State private var expandedFolders = Set<TerminalFolder.ID>()
    @State private var folderBeingRenamed: TerminalFolder?
    @State private var draftFolderTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.folders) { folder in
                        folderSection(folder)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(red: 0.055, green: 0.058, blue: 0.068).opacity(0.94)
                Color.black.opacity(0.18)
            }
        )
        .onAppear {
            expandedFolders.formUnion(store.folders.map(\.id))
        }
        .onChange(of: store.folders.map(\.id)) { _, folderIDs in
            expandedFolders.formUnion(folderIDs)
        }
        .sheet(item: $folderBeingRenamed) { folder in
            RenameFolderSheet(
                title: $draftFolderTitle,
                onCancel: {
                    folderBeingRenamed = nil
                },
                onSave: {
                    store.rename(folder, to: draftFolderTitle)
                    folderBeingRenamed = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Folders")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            Spacer()

            Button {
                store.createFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .help("New Folder")

            Button {
                store.createSession()
            } label: {
                Label("New Terminal", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .labelStyle(.iconOnly)
            .foregroundStyle(.white.opacity(0.82))
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .help("New Terminal")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func folderSection(_ folder: TerminalFolder) -> some View {
        DisclosureGroup(isExpanded: binding(for: folder.id)) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folder.sessions) { session in
                    TerminalSidebarRow(
                        session: session,
                        isSelected: store.selection == session.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selection = session.id
                    }
                    .contextMenu {
                        Button("Duplicate", systemImage: "plus.square.on.square") {
                            store.selection = session.id
                            store.duplicateSelectedSession()
                        }

                        Button("Mark Needs Attention", systemImage: "bell.badge") {
                            store.selection = session.id
                            store.markSelectedNeedsAttention()
                        }

                        Divider()

                        Button("Close", systemImage: "xmark") {
                            store.selection = session.id
                            store.closeSelectedSession()
                        }
                        .disabled(store.sessions.count == 1)
                    }
                }
            }
            .padding(.top, 3)
            .padding(.leading, 16)
        } label: {
            FolderSidebarRow(folder: folder)
                .contextMenu {
                    Button("New Terminal", systemImage: "plus") {
                        store.createSession(in: folder.id)
                    }

                    Button("Rename Folder", systemImage: "pencil") {
                        draftFolderTitle = folder.title
                        folderBeingRenamed = folder
                    }
                }
        }
        .disclosureGroupStyle(.automatic)
        .tint(.white.opacity(0.46))
    }

    private func binding(for folderID: TerminalFolder.ID) -> Binding<Bool> {
        Binding {
            expandedFolders.contains(folderID)
        } set: { isExpanded in
            if isExpanded {
                expandedFolders.insert(folderID)
            } else {
                expandedFolders.remove(folderID)
            }
        }
    }
}

private struct FolderSidebarRow: View {
    let folder: TerminalFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
                .frame(width: 18)

            Text(folder.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TerminalSidebarRow: View {
    let session: TerminalSession
    let isSelected: Bool

    var body: some View {
        Text(session.title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(.white.opacity(isSelected ? 0.94 : 0.68))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.white.opacity(0.11) : Color.clear)
            )
    }
}

private struct RenameFolderSheet: View {
    @Binding var title: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Folder")
                .font(.headline)

            TextField("Folder name", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

#Preview {
    SidebarView(store: .preview)
}
