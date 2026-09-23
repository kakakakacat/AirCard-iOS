import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }
    var label: String { self == .english ? "English" : "中文" }
}

private func tr(_ language: AppLanguage, _ english: String, _ chinese: String) -> String {
    language == .english ? english : chinese
}

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel
    @AppStorage("aircard.ui.language") private var languageRaw = AppLanguage.english.rawValue

    @State private var showImporter = false
    @State private var showDeletePairing = false
    @State private var showScanConfirmation = false
    @State private var copiedAll = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .english
    }

    private var allHashes: String {
        vm.cards.map(\.id).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    hero
                    pairingCard
                    scanCard
                    resultsCard
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Wallet Hash Exporter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Language", selection: $languageRaw) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.label).tag(language.rawValue)
                            }
                        }
                    } label: {
                        Label(language.label, systemImage: "globe")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                _ = vm.importPairingFile(from: url, originalName: url.lastPathComponent)
            }
            .confirmationDialog(
                tr(language, "Delete pairing file?", "删除配对文件？"),
                isPresented: $showDeletePairing,
                titleVisibility: .visible
            ) {
                Button(tr(language, "Delete", "删除"), role: .destructive) {
                    vm.deletePairingFile()
                }
                Button(tr(language, "Cancel", "取消"), role: .cancel) {}
            }
            .alert(
                tr(language, "Wallet cards will temporarily disappear", "Wallet 卡片会暂时消失"),
                isPresented: $showScanConfirmation
            ) {
                Button(tr(language, "Cancel", "取消"), role: .cancel) {}
                Button(tr(language, "I Understand — Read Wallet", "我已了解，读取 Wallet"), role: .destructive) {
                    vm.startCardScanning()
                }
            } message: {
                Text(tr(
                    language,
                    "This reads Wallet metadata directly and temporarily moves live Wallet files. Card availability may be interrupted. Save every hash, restart the iPhone, and wait a few minutes for recovery.",
                    "此操作会直接读取 Wallet 元数据，并暂时移动 Wallet 的实时文件，卡片可能短时间不可用。请保存全部 Hash，然后重启 iPhone 并等待几分钟恢复。"
                ))
            }
            .alert(
                tr(language, "Notice", "提示"),
                isPresented: Binding(
                    get: { vm.errorMessage != nil },
                    set: { if !$0 { vm.errorMessage = nil } }
                )
            ) {
                Button(tr(language, "OK", "确定")) { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .onAppear {
                vm.refreshPairingFile()
                vm.refreshNetworkStatus()
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.18))
                        .frame(width: 54, height: 54)
                    Image(systemName: "wallet.pass.fill")
                        .font(.system(size: 27, weight: .semibold))
                }
                Spacer()
                Text("v1.4")
                    .font(.caption.bold().monospaced())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.16), in: Capsule())
            }

            Text(tr(language, "Export all Wallet card hashes", "导出全部 Wallet 卡片 Hash"))
                .font(.title2.bold())
            Text(tr(
                language,
                "Pair once, then read all available card names and hashes directly from the Wallet database.",
                "完成一次配对后，直接从 Wallet 数据库读取全部可用卡片的名称和 Hash。"
            ))
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.86))
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.blue, Color.indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                number: "1",
                title: tr(language, "Pair the iPhone", "配对 iPhone"),
                subtitle: tr(language, "Required before Wallet can be read", "读取 Wallet 前必须完成")
            )

            HStack(spacing: 12) {
                Image(systemName: vm.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(vm.hasPairingFile ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.hasPairingFile
                         ? tr(language, "Pairing ready", "配对已就绪")
                         : tr(language, "Pairing required", "需要配对"))
                        .font(.headline)
                    Text(vm.hasPairingFile
                         ? "\(vm.pairingFileName) · \(vm.pairingFileSizeString)"
                         : tr(language, "Create or import a pairing file", "创建或导入配对文件"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if vm.pairingPhase == .pairing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(tr(language, "Waiting for pairing approval…", "等待确认配对…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let pin = vm.pairingPIN {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr(language, "Enter this PIN in Settings", "请在系统设置中输入此 PIN"))
                            .font(.caption.bold())
                        HStack {
                            Text(pin)
                                .font(.system(size: 38, weight: .black, design: .monospaced))
                                .foregroundStyle(.orange)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = pin
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }
                        Text(tr(
                            language,
                            "Settings › Privacy & Security › Developer Mode › Pair with AirCard-iOS",
                            "设置 › 隐私与安全性 › 开发者模式 › 与 AirCard-iOS 配对"
                        ))
                        .font(.footnote)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                Button(tr(language, "Cancel Pairing", "取消配对"), role: .cancel) {
                    vm.cancelPairing()
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    Button {
                        vm.startPairing()
                    } label: {
                        Label(
                            vm.hasPairingFile
                                ? tr(language, "Pair Again", "重新配对")
                                : tr(language, "Pair This iPhone", "配对此 iPhone"),
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(tr(language, "Import Pairing File", "导入配对文件"))
                }

                if vm.hasPairingFile {
                    Button(tr(language, "Delete pairing file", "删除配对文件"), role: .destructive) {
                        showDeletePairing = true
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: vm.vpnUp ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(vm.vpnUp ? .green : .orange)
                Text(vm.vpnUp
                     ? tr(language, "LocalDevVPN connected", "LocalDevVPN 已连接")
                     : tr(language, "Connect LocalDevVPN before reading Wallet", "读取 Wallet 前请连接 LocalDevVPN"))
                    .font(.caption)
                Spacer()
                if !vm.vpnUp {
                    Link(tr(language, "Open", "打开"), destination: URL(string: "localdevvpn://")!)
                        .font(.caption.bold())
                }
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .panelStyle()
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                number: "2",
                title: tr(language, "Read Wallet directly", "直接读取 Wallet"),
                subtitle: tr(language, "One operation collects every available card", "一次获取全部可用卡片")
            )

            VStack(alignment: .leading, spacing: 8) {
                Label(tr(language, "Read before continuing", "操作前请阅读"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.red)
                Text(tr(
                    language,
                    "Reading temporarily removes cards from Wallet. Card availability may be interrupted until recovery.",
                    "读取过程会导致卡片暂时从 Wallet 中消失，在恢复前卡片可能无法使用。"
                ))
                .font(.subheadline.bold())
                Text(tr(
                    language,
                    "After copying the hashes, restart the iPhone and wait a few minutes. If cards do not return, open Settings › Wallet & Apple Pay › AutoFill Cards, select any card and try to add it. When iOS says it already exists in Wallet, reopen the Wallet app.",
                    "复制 Hash 后，请重启 iPhone 并等待几分钟。如果卡片没有恢复，请打开“设置 › 钱包与 Apple Pay › 自动填充卡片”，任意选择一张卡片尝试添加。系统提示卡片已存在于钱包后，重新打开 Wallet App。"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

            Button {
                showScanConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    if vm.isScanningCards { ProgressView().tint(.white) }
                    Label(
                        vm.isScanningCards
                            ? tr(language, "Reading Wallet…", "正在读取 Wallet…")
                            : tr(language, "Read All Card Hashes", "读取全部卡片 Hash"),
                        systemImage: "externaldrive.badge.magnifyingglass"
                    )
                    Spacer()
                }
                .font(.headline)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.hasPairingFile || !vm.vpnUp || vm.isScanningCards)

            if !vm.hasPairingFile || !vm.vpnUp {
                Text(tr(
                    language,
                    "Complete pairing and connect LocalDevVPN to enable Wallet reading.",
                    "完成配对并连接 LocalDevVPN 后才能读取 Wallet。"
                ))
                .font(.caption)
                .foregroundStyle(.orange)
            } else if !vm.scanStatusText.isEmpty {
                Text(vm.scanStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(
                number: "3",
                title: tr(language, "Save the hashes", "保存 Hash"),
                subtitle: tr(language, "Use them later with the desktop tool", "稍后交给电脑端工具使用")
            )

            if vm.cards.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(tr(language, "No Wallet hashes have been read yet", "尚未读取 Wallet Hash"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                Button {
                    UIPasteboard.general.string = allHashes
                    copiedAll = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedAll = false }
                } label: {
                    Label(
                        copiedAll ? tr(language, "Copied", "已复制") : tr(language, "Copy All Hashes", "复制全部 Hash"),
                        systemImage: copiedAll ? "checkmark.circle.fill" : "doc.on.doc.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(copiedAll ? .green : .blue)

                ForEach(Array(vm.cards.enumerated()), id: \.element.id) { index, card in
                    HashRow(
                        title: card.displayName ?? tr(language, "Card \(index + 1)", "卡片 \(index + 1)"),
                        hash: card.id
                    )
                    if index < vm.cards.count - 1 { Divider() }
                }

                Text(tr(
                    language,
                    "Only use these hashes with the desktop card-artwork tool. This iPhone app does not change artwork.",
                    "这些 Hash 仅用于电脑端卡片封面工具。本 iPhone App 不提供封面更换功能。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(tr(language, "Clear saved hashes", "清空已保存 Hash"), role: .destructive) {
                    vm.clearAllCards()
                }
                .font(.caption)
            }
        }
        .panelStyle()
    }

    private func sectionHeader(number: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            Text(number)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct HashRow: View {
    let title: String
    let hash: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.bold())
            HStack(alignment: .top, spacing: 10) {
                Text(hash)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = hash
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .tint(copied ? .green : .blue)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension View {
    func panelStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5)
            )
    }
}
