//
//  LCProxy.swift
//  LiveContainerSwiftUI
//
//  SOCKS5 proxy configuration model and manager.
//

import Foundation
import Combine

struct LCProxy: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String?
    var password: String?
    
    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
    
    var displaySubtitle: String {
        if let username, !username.isEmpty {
            return "\(username)@\(host):\(port)"
        }
        return "\(host):\(port)"
    }
}

final class LCProxyManager: ObservableObject {
    static let shared = LCProxyManager()
    
    private let storageKey = "LCProxies"
    private let defaults: UserDefaults
    
    @Published private(set) var proxies: [LCProxy] = []
    
    private init(defaults: UserDefaults = LCUtils.appGroupUserDefault) {
        self.defaults = defaults
        load()
    }
    
    func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            proxies = []
            return
        }
        do {
            proxies = try JSONDecoder().decode([LCProxy].self, from: data)
        } catch {
            print("[LCProxyManager] Failed to decode proxies: \(error)")
            proxies = []
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(proxies)
            defaults.set(data, forKey: storageKey)
        } catch {
            print("[LCProxyManager] Failed to encode proxies: \(error)")
        }
    }
    
    func add(_ proxy: LCProxy) {
        proxies.append(proxy)
        save()
    }
    
    func update(_ proxy: LCProxy) {
        guard let index = proxies.firstIndex(where: { $0.id == proxy.id }) else { return }
        proxies[index] = proxy
        save()
    }
    
    func delete(_ proxy: LCProxy) {
        proxies.removeAll { $0.id == proxy.id }
        save()
    }
    
    func delete(at offsets: IndexSet) {
        proxies.remove(atOffsets: offsets)
        save()
    }
    
    func proxy(withId id: UUID?) -> LCProxy? {
        guard let id else { return nil }
        return proxies.first { $0.id == id }
    }
    
    func proxy(withIdString idString: String?) -> LCProxy? {
        guard let idString, let id = UUID(uuidString: idString) else { return nil }
        return proxy(withId: id)
    }
}
