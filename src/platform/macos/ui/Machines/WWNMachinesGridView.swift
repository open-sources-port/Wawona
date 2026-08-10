import SwiftUI

struct WWNMachinesGridView: View {
  let onConnect: (() -> Void)?
  let onOpenSettings: (() -> Void)?

  @State private var model = WWNMachinesViewModel()
  @State private var editingProfile: WWNMachineProfile?
  @State private var isEditing = false
  @State private var isCreating = false
  @State private var searchQuery = ""

  var body: some View {
    NavigationSplitView {
      List(selection: $model.selectedFilter) {
        Section("Machine Scope") {
          ForEach(WWNMachineFilter.allCases, id: \.id) { filter in
            NavigationLink(value: filter) {
              Label(filter.rawValue, systemImage: filterIcon(filter))
            }
          }
        }
        Section("Overview") {
          Button {
            model.selectedFilter = .all
          } label: {
            sidebarMetric("Profiles", value: "\(model.profiles.count)", icon: "square.grid.2x2")
          }
          .buttonStyle(.plain)
          Button {
            model.selectedFilter = .remote
          } label: {
            sidebarMetric("Connected", value: "\(model.connectedCount)", icon: "wave.3.right.circle")
          }
          .buttonStyle(.plain)
          Button {
            model.selectedFilter = .local
          } label: {
            sidebarMetric("Ready", value: "\(model.launchableCount)", icon: "play.circle")
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("Control Panel")
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          summaryStrip
          searchAndLayoutBar

          if visibleProfiles.isEmpty {
            ContentUnavailableView(
              "No Matching Machines",
              systemImage: "magnifyingglass",
              description: Text("Adjust search/filter settings or add a new machine profile.")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: adaptiveCardWidth), spacing: 14)], spacing: 14) {
              ForEach(visibleProfiles, id: \.machineId) { profile in
                WWNMachineCardView(
                  profile: profile,
                  status: model.status(for: profile.machineId),
                  typeLabel: model.machineTypeLabel(for: profile),
                  scopeLabel: model.machineScopeLabel(for: profile),
                  subtitle: model.machineSubtitle(for: profile),
                  summary: model.machineConfigurationSummary(for: profile),
                  launchSupported: model.launchSupported(for: profile),
                  isActive: profile.machineId == model.activeMachineId,
                  onEdit: {
                    editingProfile = profile
                    isEditing = true
                  },
                  onDelete: { model.delete(profile) },
                  onConnect: {
                    model.connect(profile) {
                      onConnect?()
                    }
                  }
                )
                .transition(.scale(scale: 0.95).combined(with: .opacity))
              }
            }
          }
        }
        .padding(16)
      }
      .navigationTitle("Machine Configuration")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            isCreating = true
          } label: {
            Label("Add Profile", systemImage: "plus")
          }
        }
        if let onOpenSettings {
          ToolbarItem(placement: .automatic) {
            Button("Settings", action: onOpenSettings)
          }
        }
      }
    }
    .sheet(isPresented: $isCreating) {
      WWNMachineEditorView(title: "Add Machine Profile", initial: nil) { profile in
        model.upsert(profile)
      }
    }
    .sheet(isPresented: $isEditing) {
      WWNMachineEditorView(title: "Edit Machine Profile", initial: editingProfile) { profile in
        model.upsert(profile)
      }
    }
    .animation(.spring(duration: 0.42, bounce: 0.26), value: visibleProfiles.count)
  }

  private var adaptiveCardWidth: CGFloat {
    340
  }

  private var visibleProfiles: [WWNMachineProfile] {
    let base = model.filteredProfiles
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if query.isEmpty { return base }
    return base.filter { profile in
      profile.name.lowercased().contains(query) ||
        profile.sshHost.lowercased().contains(query) ||
        profile.sshUser.lowercased().contains(query) ||
        model.machineTypeLabel(for: profile).lowercased().contains(query)
    }
  }

  private var summaryStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        Label("Machines", systemImage: "server.rack")
          .font(.headline.weight(.semibold))
        summaryPill("Profiles", "\(model.profiles.count)")
        summaryPill("Connected", "\(model.connectedCount)")
        summaryPill("Ready", "\(model.launchableCount)")
        Button {
          isCreating = true
        } label: {
          Label("New Machine", systemImage: "plus.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        if let onOpenSettings {
          Button("Settings", action: onOpenSettings)
            .buttonStyle(.bordered)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var searchAndLayoutBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Search machines, hosts, or type", text: $searchQuery)
        .textFieldStyle(.roundedBorder)
      HStack(spacing: 12) {
        Picker("Scope", selection: $model.selectedFilter) {
          ForEach(WWNMachineFilter.allCases, id: \.id) { filter in
            Text(filter.rawValue).tag(filter)
          }
        }
        .pickerStyle(.segmented)
      }
    }
  }

  private func summaryPill(_ title: String, _ value: String) -> some View {
    HStack(spacing: 6) {
      Text(title)
      Text(value).fontWeight(.bold)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color.secondary.opacity(0.14), in: Capsule())
  }

  private func sidebarMetric(_ title: String, value: String, icon: String) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }
  }

  private func filterIcon(_ filter: WWNMachineFilter) -> String {
    switch filter {
    case .all: return "circle.grid.2x2"
    case .local: return "desktopcomputer"
    case .remote: return "network"
    }
  }
}


import AppKit

@objc(WWNMachinesHostingBridge)
@objcMembers
final class WWNMachinesHostingBridge: NSObject {
  @objc(buildMacMachinesWindowControllerWithOnConnect:)
  static func buildMacMachinesWindowController(onConnect: (() -> Void)?) -> NSWindowController {
    let root = WWNMachinesGridView(
      onConnect: onConnect,
      onOpenSettings: { WWNPreferences.shared().show(NSApp) }
    )
    let hosting = NSHostingController(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = hosting
    window.title = "Muplar Wayland Machine Control Panel"
    return NSWindowController(window: window)
  }
}
