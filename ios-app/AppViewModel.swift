import Foundation
import UIKit
import AirliftFFI

struct CardHashItem: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String?
}

@MainActor
final class AppViewModel: ObservableObject {
    static var sharedLogSink: ((String) -> Void)?
    static weak var shared: AppViewModel?

    @Published var pairingStatus = ""
    @Published var pairingPIN: String?
    @Published var hasPairingFile = false
    @Published var pairingFileName = ""
    @Published var pairingPhase: PairingPhase = .idle
    @Published var vpnUp = false
    @Published var networkDetail = ""
    @Published var deviceIP = "10.7.0.1"

    @Published var cards: [CardHashItem] = []
    @Published var isScanningCards = false
    @Published var scanStatusText = ""
    @Published var errorMessage: String?
    @Published var log: [String] = []

    enum PairingPhase: Equatable {
        case idle
        case pairing
    }

    private let savedCardsKey = "aircard.hash-scanner.cards"
    private let savedNamesKey = "aircard.hash-scanner.names"
    private var activeScanID: UUID?
    private var scanWorkerRunning = false
    private var scanBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        Self.shared = self
        refreshPairingFile()
        loadSavedCards()
        refreshNetworkStatus()
        Self.sharedLogSink = { [weak self] line in
            self?.log.append(line)
        }
    }

    // MARK: - Pairing

    @discardableResult
    func importPairingFile(from sourceURL: URL, originalName: String? = nil) -> Bool {
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            errorMessage = "The selected pairing file is empty or unreadable."
            return false
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = documents.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = documents.appendingPathComponent("airlift_pairing.plist")
        do {
            try data.write(to: aircardURL, options: .atomic)
            try data.write(to: airliftURL, options: .atomic)
            PairingController.customPairingFilePath = aircardURL.path
            refreshPairingFile()
            pairingStatus = "Pairing file loaded."
            return true
        } catch {
            errorMessage = "Failed to save pairing file: \(error.localizedDescription)"
            return false
        }
    }

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path)
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
    }

    var pairingFileSizeString: String {
        let path = PairingController.pairingFilePath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func startPairing() {
        pairingPhase = .pairing
        pairingPIN = nil
        pairingStatus = "Starting local host…"
        errorMessage = nil
        let controller = PairingController.shared

        Task {
            do {
                let path = try await controller.startAndWait()
                pairingPhase = .idle
                refreshPairingFile()
                pairingStatus = "Paired successfully."
                log.append("Pairing complete: \(path)")
            } catch is CancellationError {
                pairingPhase = .idle
                pairingStatus = "Cancelled."
            } catch {
                pairingPhase = .idle
                pairingStatus = ""
                errorMessage = "Pairing failed: \(error.localizedDescription)"
            }
        }

        Task {
            while pairingPhase == .pairing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard pairingPhase == .pairing else { return }
                pairingStatus = controller.pairingStatus
                pairingPIN = controller.pairingPIN
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingStatus = ""
    }

    func deletePairingFile() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for name in ["aircard_pairing.plist", "airlift_pairing.plist"] {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
        PairingController.customPairingFilePath = nil
        refreshPairingFile()
        pairingStatus = "Pairing file deleted."
    }

    func refreshNetworkStatus() {
        let status = NetworkStatus.summarize(deviceIP: deviceIP)
        vpnUp = status.0
        networkDetail = status.2
    }

    // MARK: - Hash scan

    func startCardScanning() {
        guard !isScanningCards, !scanWorkerRunning else { return }
        guard hasPairingFile else {
            errorMessage = "Pairing is required before scanning."
            return
        }

        let scanID = UUID()
        activeScanID = scanID
        scanWorkerRunning = true
        isScanningCards = true
        scanStatusText = "Reading Wallet metadata…"
        errorMessage = nil
        log.append("[WalletDB] scan started")

        scanBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Wallet hash scan") { [weak self] in
            self?.activeScanID = nil
            self?.isScanningCards = false
        }

        let pairingPath = PairingController.pairingFilePath()
        let thread = Thread {
            let manager = FileManager.default
            let workDirectory = manager.temporaryDirectory
                .appendingPathComponent("wallet_hash_scan_\(UUID().uuidString)", isDirectory: true)
            try? manager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: workDirectory) }

            func export(_ devicePath: String, to localURL: URL) -> String? {
                try? manager.removeItem(at: localURL)
                var outputError: UnsafeMutablePointer<CChar>?
                let result = pairingPath.withCString { pairingCString in
                    devicePath.withCString { sourceCString in
                        localURL.path.withCString { destinationCString in
                            al_exploit_read_file(
                                pairingCString,
                                sourceCString,
                                destinationCString,
                                { _, message in
                                    guard let message else { return }
                                    let line = String(cString: message)
                                    DispatchQueue.main.async { AppViewModel.shared?.log.append(line) }
                                },
                                nil,
                                &outputError
                            )
                        }
                    }
                }
                let message = outputError.flatMap { String(validatingUTF8: $0) }
                if let outputError { al_string_free(outputError) }
                return result == 0 ? nil : (message ?? "read failed (\(result))")
            }

            let databaseURL = workDirectory.appendingPathComponent("passes23.sqlite")
            var failure = export("/var/mobile/Library/Passes/passes23.sqlite", to: databaseURL)
            var candidates: [WalletMetadataCard] = []

            if failure == nil {
                do {
                    candidates = try WalletMetadataScanner.readCards(from: databaseURL)
                } catch {
                    _ = export(
                        "/var/mobile/Library/Passes/passes23.sqlite-wal",
                        to: workDirectory.appendingPathComponent("passes23.sqlite-wal")
                    )
                    _ = export(
                        "/var/mobile/Library/Passes/passes23.sqlite-shm",
                        to: workDirectory.appendingPathComponent("passes23.sqlite-shm")
                    )
                    do {
                        candidates = try WalletMetadataScanner.readCards(from: databaseURL)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }

            var verified: [CardHashItem] = []
            for (index, candidate) in candidates.prefix(64).enumerated() {
                let passJSON = workDirectory.appendingPathComponent("pass_\(index).json")
                let path = "/var/mobile/Library/Passes/Cards/\(candidate.id).pkpass/pass.json"
                if export(path, to: passJSON) == nil {
                    verified.append(CardHashItem(
                        id: candidate.id,
                        displayName: WalletMetadataScanner.passName(from: passJSON) ?? candidate.name
                    ))
                }
            }

            DispatchQueue.main.async {
                guard let model = AppViewModel.shared else { return }
                model.scanWorkerRunning = false
                model.endScanBackgroundTask()
                guard model.activeScanID == scanID else { return }
                model.activeScanID = nil
                model.isScanningCards = false

                if verified.isEmpty {
                    model.scanStatusText = "Scan failed."
                    model.errorMessage = failure ?? "No Wallet card hashes were found."
                } else {
                    model.cards = verified
                    model.saveCards()
                    model.scanStatusText = "Found \(verified.count) card hashes. Copy and save them now."
                    model.log.append("[WalletDB] scan complete: \(verified.count) hashes")
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
        }
        thread.name = "AirCard.HashScanner"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopCardScanning() {
        // The protected-file operation cannot be cancelled safely once started.
        // Keep the UI in its running state until the worker reports completion.
    }

    func clearAllCards() {
        cards.removeAll()
        saveCards()
        scanStatusText = ""
    }

    private func endScanBackgroundTask() {
        guard scanBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(scanBackgroundTask)
        scanBackgroundTask = .invalid
    }

    private func saveCards() {
        UserDefaults.standard.set(cards.map(\.id), forKey: savedCardsKey)
        let names = Dictionary(uniqueKeysWithValues: cards.compactMap { item in
            item.displayName.map { (item.id, $0) }
        })
        UserDefaults.standard.set(names, forKey: savedNamesKey)
    }

    private func loadSavedCards() {
        let hashes = UserDefaults.standard.stringArray(forKey: savedCardsKey) ?? []
        let names = UserDefaults.standard.dictionary(forKey: savedNamesKey) as? [String: String] ?? [:]
        cards = hashes.map { CardHashItem(id: $0, displayName: names[$0]) }
    }
}
