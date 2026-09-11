//
//  LCProxiesView.swift
//  LiveContainerSwiftUI
//
//  Global SOCKS5 proxy list management.
//

import SwiftUI

struct LCProxiesView: View {
    @ObservedObject private var manager = LCProxyManager.shared
    @State private var editingProxy: LCProxy?
    @State private var showingEditor = false
    @State private var isCreating = false
    
    var body: some View {
        Form {
            Section {
                if manager.proxies.isEmpty {
                    Text("No proxies configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.proxies) { proxy in
                        Button {
                            editingProxy = proxy
                            isCreating = false
                            showingEditor = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(proxy.name)
                                        .foregroundStyle(.primary)
                                    Text(proxy.displaySubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        manager.delete(at: offsets)
                    }
                }
            } footer: {
                Text("Add SOCKS5 proxies here, then assign them to individual app containers in the container settings.")
            }
            
            Section {
                Button {
                    editingProxy = LCProxy(name: "", host: "", port: 1080)
                    isCreating = true
                    showingEditor = true
                } label: {
                    Label("Add Proxy", systemImage: "plus.circle.fill")
                }
            }
        }
        .navigationTitle("Proxies")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingEditor) {
            if let proxy = editingProxy {
                LCProxyEditorView(
                    proxy: proxy,
                    isCreating: isCreating,
                    onSave: { saved in
                        if isCreating {
                            manager.add(saved)
                        } else {
                            manager.update(saved)
                        }
                        showingEditor = false
                    },
                    onCancel: {
                        showingEditor = false
                    },
                    onDelete: isCreating ? nil : {
                        manager.delete(proxy)
                        showingEditor = false
                    }
                )
            }
        }
    }
}

struct LCProxyEditorView: View {
    @State var proxy: LCProxy
    let isCreating: Bool
    let onSave: (LCProxy) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    
    @State private var showDeleteConfirm = false
    
    private var canSave: Bool {
        !proxy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !proxy.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        proxy.port > 0 && proxy.port <= 65535
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("My Proxy", text: $proxy.name)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("127.0.0.1", text: $proxy.host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("1080", value: $proxy.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("Server")
                }
                
                Section {
                    HStack {
                        Text("Username")
                        Spacer()
                        TextField("Optional", text: Binding(
                            get: { proxy.username ?? "" },
                            set: { proxy.username = $0.isEmpty ? nil : $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("Optional", text: Binding(
                            get: { proxy.password ?? "" },
                            set: { proxy.password = $0.isEmpty ? nil : $0 }
                        ))
                        .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Leave username and password empty if the proxy does not require authentication.")
                }
                
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("Delete Proxy")
                        }
                    }
                }
            }
            .navigationTitle(isCreating ? "Add Proxy" : "Edit Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        proxy.name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        proxy.host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(proxy)
                    }
                    .disabled(!canSave)
                }
            }
            .alert("Delete Proxy?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    onDelete?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Containers using this proxy will fall back to no proxy.")
            }
        }
    }
}
