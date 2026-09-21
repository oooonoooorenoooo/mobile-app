import UIKit
import SwiftUI
import ComposeApp
import Security

private enum HAAnnouncementSettings {
    static let urlKey = "ha_announcement_base_url"
    private static let tokenAccount = "ha_announcement_access_token"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
    }

    static var token: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Bundle.main.bundleIdentifier ?? "io.music-assistant.mobile-client",
                kSecAttrAccount as String: tokenAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let service = Bundle.main.bundleIdentifier ?? "io.music-assistant.mobile-client"
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: tokenAccount,
            ]
            guard let newValue, !newValue.isEmpty,
                  let data = newValue.data(using: .utf8) else {
                SecItemDelete(query as CFDictionary)
                return
            }
            let attrs: [String: Any] = [kSecValueData as String: data]
            if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(add as CFDictionary, nil)
            }
        }
    }

    static var isConfigured: Bool {
        !baseURL.isEmpty && !(token?.isEmpty ?? true)
    }

    static func websocketURL() -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/api/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Outbound Home Assistant WebSocket bridge.
///
/// The phone opens the connection itself, so this works through the user's
/// external Home Assistant URL while the phone is on cellular. HA only has to
/// fire ma_ios_announcement; no inbound connection to the iPhone is needed.
final class HAAnnouncementBridge {
    static let shared = HAAnnouncementBridge()

    private weak var player: NativeAudioController?
    private var socket: URLSessionWebSocketTask?
    private var shouldRun = false
    private var generation: UInt64 = 0
    private var subscribed = false
    private let logTag = "HAAnnouncementBridge"

    private init() {}

    func configure(player: NativeAudioController) {
        self.player = player
    }

    func start() {
        shouldRun = true
        connect()
    }

    func stop() {
        shouldRun = false
        generation &+= 1
        subscribed = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func configurationChanged() {
        guard shouldRun else { return }
        generation &+= 1
        subscribed = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connect()
    }

    private func connect() {
        guard shouldRun, socket == nil,
              HAAnnouncementSettings.isConfigured,
              let url = HAAnnouncementSettings.websocketURL() else { return }

        generation &+= 1
        let myGeneration = generation
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        NativeLog.shared.info(tag: logTag, message: "Connecting to Home Assistant announcement channel")
        receiveNext(task: task, generation: myGeneration)
        schedulePing(task: task, generation: myGeneration)
    }

    private func receiveNext(task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self] result in
            guard let self, self.shouldRun, generation == self.generation else { return }
            switch result {
            case .failure(let error):
                NativeLog.shared.error(tag: self.logTag, message: "HA WebSocket receive failed: \(error.localizedDescription)")
                self.handleDisconnect(task: task, generation: generation)
            case .success(let message):
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text {
                    self.handleMessage(text, task: task, generation: generation)
                }
                self.receiveNext(task: task, generation: generation)
            }
        }
    }

    private func handleMessage(_ text: String, task: URLSessionWebSocketTask, generation: UInt64) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "auth_required":
            guard let token = HAAnnouncementSettings.token else { return }
            sendJSON(["type": "auth", "access_token": token], task: task)
        case "auth_ok":
            NativeLog.shared.info(tag: logTag, message: "Home Assistant announcement channel authenticated")
            subscribe(task: task)
        case "auth_invalid":
            NativeLog.shared.error(tag: logTag, message: "Home Assistant rejected the announcement token")
        case "event":
            handleEvent(json)
        default:
            break
        }
    }

    private func subscribe(task: URLSessionWebSocketTask) {
        guard !subscribed else { return }
        subscribed = true
        sendJSON(
            [
                "id": 941,
                "type": "subscribe_events",
                "event_type": "ma_ios_announcement",
            ],
            task: task
        )
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? [String: Any],
              let data = event["data"] as? [String: Any],
              let url = data["url"] as? String,
              !url.isEmpty else { return }

        let duck = (data["duck"] as? NSNumber)?.doubleValue ?? 0.22
        let volume = (data["volume"] as? NSNumber)?.doubleValue ?? 1.0

        DispatchQueue.main.async { [weak self] in
            self?.player?.playOverlayAnnouncement(
                urlString: url,
                duckingLevel: duck,
                announcementVolume: volume
            )
        }
    }

    private func sendJSON(_ object: [String: Any], task: URLSessionWebSocketTask) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error {
                NativeLog.shared.error(
                    tag: self?.logTag ?? "HAAnnouncementBridge",
                    message: "HA WebSocket send failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func schedulePing(task: URLSessionWebSocketTask, generation: UInt64) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.shouldRun, generation == self.generation, self.socket === task else { return }
            task.sendPing { [weak self] error in
                guard let self else { return }
                if let error {
                    NativeLog.shared.error(tag: self.logTag, message: "HA WebSocket ping failed: \(error.localizedDescription)")
                    self.handleDisconnect(task: task, generation: generation)
                } else {
                    self.schedulePing(task: task, generation: generation)
                }
            }
        }
    }

    private func handleDisconnect(task: URLSessionWebSocketTask, generation: UInt64) {
        guard generation == self.generation, socket === task else { return }
        socket = nil
        subscribed = false
        guard shouldRun else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connect()
        }
    }
}

struct ComposeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        MainViewControllerKt.MainViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct ContentView: View {
    @State private var showHASettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ComposeView()
                .ignoresSafeArea(.keyboard)
                .ignoresSafeArea(.container)

            Button {
                showHASettings = true
            } label: {
                Image(systemName: "speaker.wave.2.badge.gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
            .accessibilityLabel("Home Assistant announcements")
        }
        .sheet(isPresented: $showHASettings) {
            HAAnnouncementSettingsView()
        }
    }
}

private struct HAAnnouncementSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = HAAnnouncementSettings.baseURL
    @State private var token = ""
    @State private var keepExistingToken = HAAnnouncementSettings.token != nil
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Home Assistant") {
                    TextField("External URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField(
                        keepExistingToken ? "Access token (unchanged if empty)" : "Long-lived access token",
                        text: $token
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("The app listens for the Home Assistant event ‘ma_ios_announcement’ while it is running/connected to CarPlay. The token is stored in the iOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("HA announcements")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalized),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else {
            validationMessage = "Enter a valid http(s) Home Assistant URL."
            return
        }

        if !keepExistingToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationMessage = "Enter a long-lived access token."
            return
        }

        HAAnnouncementSettings.baseURL = normalized
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            HAAnnouncementSettings.token = trimmedToken
            keepExistingToken = true
        }
        HAAnnouncementBridge.shared.configurationChanged()
        dismiss()
    }
}
