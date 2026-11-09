import Perception
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingSetupView: View {
    var next: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var alert: AlertState?
    @State private var filePickerDelegate: PairingFilePickerDelegate?

    private let pairing = PairingStore.shared
    private let session = Platform.shared.device.pairingSession

    var body: some View {
        WithPerceptionTracking {
            SetupPage(
                "link", Text("Pair with This Device"),
                description: description
            ) {
                PairingGuideView(hostName: session.hostName)
                VStack(alignment: .leading, spacing: 10) {
                    SetupStepLine(number: 1, text: Text("Go to Settings › Privacy & Security › Developer Mode."))
                    SetupStepLine(number: 2, text: Text("Tap “\("Pair with \(session.hostName)")”."))
                    SetupStepLine(number: 3, text: Text("Enter the pairing code shown in the Live Activity."))
                }
                switch session.state {
                case .code(let pin):
                    PairingCodeView(pin: pin)
                case .waiting:
                    InlineProgress("Waiting for Settings")
                case .idle, .failed:
                    EmptyView()
                }
            } actions: {
                SetupPrimaryButton(title: Text("Pair in Settings"), action: pairInSettings)
                if session.isInProgress {
                    SetupSecondaryButton(title: Text("Cancel")) { session.cancel() }
                } else {
                    SetupSecondaryButton(title: Text("Import Pairing File…")) { importPairingFile() }
                }
            }
            .alert(problemAlert)
            .onChangeCompat(of: pairing.revision) {
                guard pairing.isPaired else { return }
                if let next {
                    next()
                } else {
                    dismiss()
                }
            }
        }
    }

    private var description: Text {
        let description = String(localized: "Swipt needs to pair with this device to connect to its developer services.")
        return Text(verbatim: description)
    }

    private var problemAlert: Binding<AlertState?> {
        Binding {
            if let alert {
                return alert
            }
            if case .failed(let problem) = session.state {
                return AlertState(problem.title, errorMessage: problem.message)
            }
            return nil
        } set: { state in
            guard state == nil else { return }
            alert = nil
            session.acknowledgeFailure()
        }
    }

    private func pairInSettings() {
        session.start()
        guard session.isInProgress else { return }
        Task {
            if let url = URL(string: "App-Prefs:"), await UIApplication.shared.open(url) { return }
            if let url = URL(string: UIApplication.openSettingsURLString) {
                _ = await UIApplication.shared.open(url)
            }
        }
    }

    private func importPairingFile() {
        // SwiftUI .fileImporter 选不了文件（用户 2026-11-09 三次报）：
        // 修饰符挂在 SetupPage 上时，文件选择器要么不弹、要么文件
        // 置灰点不动。改走 UIKit UIDocumentPickerViewController，
        // 直接从顶层 VC present（与 LoopbackSetupView 的分享同款
        // 路子），asCopy 把文件拷进沙盒再读，不依赖安全域。
        // 类型放最宽：.item/.data/.propertyList 全要，配对记录不管
        // 是什么后缀都能点。
        guard let top = topViewController() else {
            alert = AlertState(String(localized: "Couldn’t Import the Pairing File"), error: MessageError("No window to present the file picker"))
            return
        }
        let delegate = PairingFilePickerDelegate { [weak self] url in
            self?.filePickerDelegate = nil
            if let url {
                self?.importFile(url)
            }
        }
        filePickerDelegate = delegate
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data, .propertyList], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    private func importFile(_ url: URL) {
        Task {
            do {
                try pairing.save(try await url.pickedFileContents())
            } catch {
                alert = AlertState(String(localized: "Couldn’t Import the Pairing File"), error: error)
            }
        }
    }
}

private struct PairingCodeView: View {
    let pin: String

    var body: some View {
        Text(verbatim: PairingSession.grouped(pin))
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: pin.map(String.init).joined(separator: " ")))
            .padding(.vertical, 8)
    }
}

// UIDocumentPickerViewController 的 delegate（weak 持有），由
// PairingSetupView 的 @State 强持有到选择结束才释放。
private final class PairingFilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick(nil)
    }
}
