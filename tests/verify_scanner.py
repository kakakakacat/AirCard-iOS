"""Run the actual Swift parser against the original main-branch implementation."""
from pathlib import Path
import subprocess
import tempfile

BASE = "097a058c984ffc33ccb697b9dfe8058be3e86244"
ROOT = Path(__file__).resolve().parents[1]


def original(path):
    return subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT, text=True)


def between(source, start, end):
    offset = source.index(start)
    return source[offset:source.index(end, offset)].strip()


current = (ROOT / "ios-app/AppViewModel.swift").read_text()
baseline = original("ios-app/AppViewModel.swift")
models = (ROOT / "ios-app/Models.swift").read_text()
baseline_models = original("ios-app/Models.swift")
regex_start = "nonisolated static let cardRegexes:"
regex_end = "func toggleCardScanning()"
regexes = between(current, regex_start, regex_end)
assert regexes == between(baseline, regex_start, regex_end), "Regex rules changed"
dummy = between(current, "nonisolated private static let dummyCardHashes:", "func startCardScanning()")
clean = between(models, "static func cleanCardId(", "static func ==")
baseline_clean = between(baseline_models, "static func cleanCardId(", "static func ==")
assert clean == baseline_clean, "Card ID normalization changed"
legacy = between(baseline, "func processSyslogLine(", "nonisolated static func cardImagePath")
parser = between(current, "nonisolated static func firstCardID(", "private func acceptScannedCard(")

swift = "import Foundation\n"
swift += between(current, "final class CardScanContext:", "// MARK: - AppViewModel") + "\n"
swift += "struct CardItem { let id: String; var isSelected: Bool = true; " + clean + " }\n"
swift += "struct UIImpactFeedbackGenerator { enum Style { case heavy }; init(style: Style) {}; func impactOccurred() {} }\n"
swift += "@MainActor final class Legacy {\n" + regexes + "\n" + dummy + "\n"
swift += 'var cards: [CardItem] = []; var log: [String] = []; var scanStatusText = ""; func saveCards() {}\n'
swift += legacy + "\n}\n"
swift += "@MainActor final class Optimized {\n" + regexes + "\n" + dummy + "\n" + parser + "\n}\n"
swift += r'''
@main struct ScannerTests {
    @MainActor static func main() {
        let hash = "AbCdEfGhIjKlMnOpQrStUvWxYz0="
        let second = "ZbCdEfGhIjKlMnOpQrStUvWxYz0="
        var lines = [
            "passd /var/mobile/Library/Passes/Cards/\(hash).pkpass",
            "passd /Cards/\(hash).cache",
            "passd /Cards/\(hash).pkcache",
            "passd selected \(hash)",
            "PDCardFileManager: writing card \(hash)",
            "PDPassLibrary: wrote pass \(hash)",
            "VerificationCheck.\(hash)",
            "passd uniqueID=\(hash.dropLast())",
            "passd uniqueID=12345678-1234-1234-1234-123456789abc",
            "unrelated daemon \(hash)",
            "passd <private>",
            "passd /Cards/\(hash).pkpass /Cards/\(second).pkpass",
            "passd selected M6nDwZrkYbFlsodLgCbvyFZQ1cc= \(hash)",
            "passd selected ABCDE/\(hash)",
            "passd /Cards/\(hash).pkpass/cardBackgroundCombined@3x.png",
            "passd passIdentifier=\(String(repeating: "q", count: 64))",
            "", "wallet cache"
        ]
        for length in 18...66 {
            let id = String(repeating: "A", count: length)
            for suffix in ["", "=", "==", ".pkpass", ".cache", ".pkcache"] {
                lines.append("passd /Cards/\(id)\(suffix)")
                lines.append("PDCardFileManager: writing card \(id)\(suffix)")
            }
        }
        for line in lines {
            let legacy = Legacy()
            legacy.processSyslogLine(line)
            let expected = legacy.cards.first?.id
            let actual = Optimized.firstCardID(in: line)
            precondition(actual == expected, "Parser differs from main for: \(line)")
        }
        precondition(Optimized.firstCardID(in: lines[0]) == hash)
        precondition(Optimized.firstCardID(in: lines[9]) == nil)
        let diagnostic = CardScanContext()
        precondition(Optimized.firstCardID(in: "passd <private>", diagnostics: diagnostic) == nil)
        precondition(diagnostic.wallet == 1 && diagnostic.privateWallet == 1)
        precondition(Optimized.firstCardID(in: lines[0], diagnostics: diagnostic) == hash)
        precondition(diagnostic.matches == 1 && diagnostic.matchedRule == 1)
        precondition(diagnostic.candidates == 1 && diagnostic.invalid == 0)
        // Repeated log traffic must not defer or cancel the first match.
        for _ in 0..<1000 {
            precondition(Optimized.firstCardID(in: lines[0]) == hash)
        }
        print("PASS: \(lines.count) baseline parity cases and 1000 repeated matches")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="aircard-scanner-tests-") as directory:
    source = Path(directory) / "Tests.swift"
    binary = Path(directory) / "scanner-tests"
    source.write_text(swift)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
