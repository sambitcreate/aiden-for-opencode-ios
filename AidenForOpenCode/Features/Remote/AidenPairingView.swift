import AVFoundation
import SwiftUI
import UIKit

enum AidenPairingAlertCopy {
    static let title = String(localized: "Aiden for OpenCode")
    static let fallbackMessage = String(localized: "Try again from your OpenCode server settings.")
}

enum AidenPairingMethod: String, CaseIterable, Identifiable, Hashable {
    case scanQRCode
    case manual
    case pastePayload

    var id: String { rawValue }

    static let primary: [AidenPairingMethod] = [.scanQRCode, .manual]

    var tabTitle: String {
        switch self {
        case .scanQRCode: return String(localized: "QR")
        case .manual: return String(localized: "Manual")
        case .pastePayload: return String(localized: "Payload")
        }
    }
}

enum AidenMobileOnboardingLayout {
    static let maximumContentWidth: CGFloat = 620
    static let maximumContentHeight: CGFloat = 760
    static let maximumActionWidth: CGFloat = 360
    static let actionHorizontalPadding: CGFloat = 24
    static let actionBottomPadding: CGFloat = 12
    static let artworkSide: CGFloat = 232

    static func contentWidth(for availableWidth: CGFloat) -> CGFloat {
        max(0, min(availableWidth, maximumContentWidth))
    }

    static func contentHeight(for availableHeight: CGFloat) -> CGFloat {
        max(0, min(availableHeight, maximumContentHeight))
    }
}

/// Pairing surface for OpenCode V2: scan a QR, paste a payload
/// (`aiden-opencode-pairing-v1`), or enter endpoint + password manually.
/// There is no server-side handshake — the coordinator verifies
/// `/api/health` + an authenticated probe before anything is persisted.
///
/// First run walks welcome → prepare → pairing, matching Aiden On The Go.
struct AidenPairingView: View {
    /// Pages of the first-run introduction carousel.
    private enum IntroPage: String, CaseIterable, Identifiable {
        case serve
        case secure
        case connect

        var id: String { rawValue }

        var eyebrow: String {
            switch self {
            case .serve: return String(localized: "RUN THE SERVER")
            case .secure: return String(localized: "SECURE IT")
            case .connect: return String(localized: "SAME NETWORK")
            }
        }

        var title: String {
            switch self {
            case .serve: return String(localized: "Serve OpenCode on your computer")
            case .secure: return String(localized: "Protect it with a service password")
            case .connect: return String(localized: "Pair over your Wi-Fi")
            }
        }

        var detail: String {
            switch self {
            case .serve:
                return String(localized:
                    "Start the server with opencode serve --hostname 0.0.0.0 so this device can reach it."
                )
            case .secure:
                return String(localized:
                    "Run opencode service password. Aiden signs in over HTTP Basic auth and stores the secret in your Keychain."
                )
            case .connect:
                return String(localized:
                    "Both devices share a network — or a VPN like Tailscale. Scan a QR, paste the payload, or type the address once."
                )
            }
        }

        var symbol: String {
            switch self {
            case .serve: return "desktopcomputer"
            case .secure: return "lock.shield"
            case .connect: return "bubble.left.and.bubble.right"
            }
        }
    }

    @Bindable var coordinator: AidenRemoteCoordinator
    @Environment(AidenAppearanceStore.self) private var appearance
    @Environment(\.aidenPalette) private var palette
    @Environment(\.aidenCodeTypography) private var codeTypography
    var onPaired: (() -> Void)?

    @State private var selectedIntroPage: IntroPage = .serve
    @State private var selectedPairingMethod: AidenPairingMethod = .scanQRCode
    @State private var pastedPayload = ""
    @State private var manualEndpoint = ""
    @State private var manualPassword = ""
    @State private var manualRequiresPassword = true
    @State private var manualName = ""
    @State private var isShowingScanner = false
    @State private var isShowingAppearance = false
    @State private var isShowingPayloadFallback = false
    @State private var isPairing = false
    @State private var inputProblem: String?
    @State private var failure: PairingFailure?
    @State private var installationPendingRemoval: OpenCodeInstallation?
    @State private var step: Int

    private let onIntroductionComplete: (() -> Void)?
    private let showsIntroduction: Bool

    init(
        coordinator: AidenRemoteCoordinator,
        showsIntroduction: Bool = true,
        onIntroductionComplete: (() -> Void)? = nil,
        onPaired: (() -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.onIntroductionComplete = onIntroductionComplete
        self.onPaired = onPaired
        self.showsIntroduction = showsIntroduction
        _step = State(initialValue: onPaired == nil && showsIntroduction ? 0 : 2)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: welcomePage
                case 1: preparePage
                default: pairingPage
                }
            }
            .background(palette.canvas)
            .toolbar {
                if step > 0 && onPaired == nil && showsIntroduction {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { step -= 1 } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 2 {
                        Menu {
                            Button {
                                isShowingPayloadFallback = true
                            } label: {
                                Label("Paste Pairing Payload", systemImage: "doc.on.clipboard")
                            }
                            Button {
                                isShowingAppearance = true
                            } label: {
                                Label("Appearance", systemImage: "circle.lefthalf.filled")
                            }
                        } label: {
                            Image(systemName: AidenChromeSymbols.overflowMenu)
                        }
                        .accessibilityLabel("More pairing options")
                    } else {
                        Button {
                            isShowingAppearance = true
                        } label: {
                            Image(systemName: "circle.lefthalf.filled")
                        }
                        .accessibilityLabel("Appearance")
                    }
                }
            }
            .overlay {
                if isPairing {
                    ProgressView("Connecting…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $isShowingScanner) {
                NavigationStack {
                    AidenQRCodeScanner { raw in
                        isShowingScanner = false
                        handleScannedPayload(raw)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Pairing QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isShowingScanner = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingAppearance) {
                AidenAppearanceSettingsView(appearance: appearance)
            }
            .sheet(isPresented: $isShowingPayloadFallback) {
                NavigationStack {
                    pastePayloadPairingPage
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isShowingPayloadFallback = false }
                            }
                        }
                }
            }
            .confirmationDialog(
                removalDialogTitle,
                isPresented: Binding(
                    get: { installationPendingRemoval != nil },
                    set: { if !$0 { installationPendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: installationPendingRemoval
            ) { installation in
                Button(String(localized: "Remove"), role: .destructive) {
                    Task { await coordinator.removeInstallation(id: installation.id) }
                    installationPendingRemoval = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) { installationPendingRemoval = nil }
            } message: { _ in
                Text("The saved details and password are deleted from this device. The server keeps running.")
            }
            .alert(
                AidenPairingAlertCopy.title,
                isPresented: Binding(
                    get: { coordinator.presentedError != nil },
                    set: { if !$0 { coordinator.presentedError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { coordinator.presentedError = nil }
            } message: {
                Text(coordinator.presentedError ?? AidenPairingAlertCopy.fallbackMessage)
            }
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                brandHeader
                TabView(selection: $selectedIntroPage) {
                    ForEach(IntroPage.allCases) { page in
                        onboardingPhasePage(page)
                            .tag(page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityLabel(String(localized: "Aiden for OpenCode"))
            }
            .frame(
                width: AidenMobileOnboardingLayout.contentWidth(for: proxy.size.width),
                height: AidenMobileOnboardingLayout.contentHeight(for: proxy.size.height)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                introPageIndicator
                onboardingActionButton(action: advanceIntroduction) {
                    Text(isLastIntroPage ? String(localized: "Set Up Connection") : String(localized: "Continue"))
                }
            }
            .padding(.bottom, AidenMobileOnboardingLayout.actionBottomPadding)
        }
        .navigationBarHidden(true)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image("AidenAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Aiden for OpenCode"))
                    .font(.headline)
                Text(String(localized: "Your OpenCode server, from anywhere."))
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private func onboardingPhasePage(_ page: IntroPage) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                introPageContent(page)
                Spacer(minLength: 16)
            }

            ScrollView {
                introPageContent(page)
                    .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func introPageContent(_ page: IntroPage) -> some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(0.07))
                    .frame(width: 232, height: 232)
                Circle()
                    .stroke(palette.accent.opacity(0.14), lineWidth: 1)
                    .frame(width: 196, height: 196)
                Image(systemName: page.symbol)
                    .font(.system(size: 84, weight: .light))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Text(page.eyebrow)
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(palette.accent)
                Text(page.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(page.detail)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 26)
        }
        .frame(maxWidth: .infinity)
    }

    private var isLastIntroPage: Bool {
        selectedIntroPage == IntroPage.allCases.last
    }

    private var introPageIndicator: some View {
        HStack(spacing: 4) {
            ForEach(IntroPage.allCases) { page in
                Button {
                    selectedIntroPage = page
                } label: {
                    Capsule()
                        .fill(page == selectedIntroPage ? palette.accent : palette.secondary.opacity(0.24))
                        .frame(width: page == selectedIntroPage ? 22 : 7, height: 7)
                        .frame(width: 34, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(page == selectedIntroPage ? [.isSelected] : [])
            }
        }
    }

    private func advanceIntroduction() {
        if isLastIntroPage {
            step = 1
        } else if let index = IntroPage.allCases.firstIndex(of: selectedIntroPage) {
            selectedIntroPage = IntroPage.allCases[index + 1]
        }
    }

    private func onboardingActionButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        prominentGlassButton(action: action, label: label)
            .frame(maxWidth: AidenMobileOnboardingLayout.maximumActionWidth)
            .padding(.horizontal, AidenMobileOnboardingLayout.actionHorizontalPadding)
    }

    @ViewBuilder
    private func prominentGlassButton<Label: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let button = Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .foregroundStyle(palette.onAccent)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .controlSize(.large)
        .tint(palette.accent)

        if #available(iOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Prepare

    private var preparePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Prepare your computer"))
                        .font(.largeTitle.bold())
                    Text(String(localized: "Three quick steps on the machine running OpenCode."))
                        .foregroundStyle(palette.secondary)
                }

                pairingStep(
                    number: 1,
                    title: String(localized: "Serve OpenCode"),
                    detail: String(localized: "Starts the server on your local network.")
                ) {
                    commandRow("opencode serve --hostname 0.0.0.0")
                }

                pairingStep(
                    number: 2,
                    title: String(localized: "Set a service password"),
                    detail: String(localized: "Prints or sets the password Aiden signs in with.")
                ) {
                    commandRow("opencode service password")
                }

                pairingStep(
                    number: 3,
                    title: String(localized: "Stay on the same network"),
                    detail: String(localized: "Both devices need the same Wi-Fi network, or a VPN like Tailscale.")
                )

                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Password stored only in your Keychain"), systemImage: "key.fill")
                    Label(String(localized: "Direct LAN connection — no cloud relay"), systemImage: "lock.shield.fill")
                    Label(String(localized: "Remove the server anytime here"), systemImage: "checkmark.shield")
                }
                .font(.subheadline)
                .foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: AidenMobileOnboardingLayout.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            onboardingActionButton(action: {
                onIntroductionComplete?()
                step = 2
            }) {
                Text("Choose How to Connect")
            }
            .padding(.bottom, AidenMobileOnboardingLayout.actionBottomPadding)
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pairingPage: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose how this device should reach your OpenCode server.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Connection method", selection: $selectedPairingMethod) {
                    ForEach(AidenPairingMethod.primary) { method in
                        Text(method.tabTitle).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Swipe the content below or choose a tab.")
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)

            TabView(selection: $selectedPairingMethod) {
                qrPairingPage.tag(AidenPairingMethod.scanQRCode)
                manualPairingPage.tag(AidenPairingMethod.manual)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityLabel("Connection setup")
        }
        .background(palette.canvas)
        .navigationTitle("Pair OpenCode")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var pairedServersSection: some View {
        if !coordinator.installationStore.installations.isEmpty {
            Section {
                ForEach(coordinator.installationStore.installations) { installation in
                    installationRow(installation)
                }
            } header: {
                Text("Paired servers")
            } footer: {
                Text("Tap to switch. Swipe to remove.")
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let failure {
            Section {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(failure == .unreachable || failure == .unauthorized ? palette.danger : palette.warning)
            }
        } else if let inputProblem {
            Section {
                Label(inputProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.warning)
            }
        }
    }

    private var qrPairingPage: some View {
        Form {
            pairedServersSection
            statusSection
            Section {
                Label("Show the pairing QR from your computer's terminal", systemImage: "desktopcomputer")
                Label("Keep both devices on the same network", systemImage: "network")
            } header: {
                Text("On your computer")
            }

            Section("Private pairing") {
                Text("The QR carries the server address and password. Aiden stores the secret in Keychain after a successful probe.")
                    .foregroundStyle(palette.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            onboardingActionButton(action: openScanner) {
                Label("Open Camera", systemImage: "qrcode.viewfinder")
            }
            .disabled(isPairing)
            .padding(.bottom, AidenMobileOnboardingLayout.actionBottomPadding)
        }
    }

    private var manualPairingPage: some View {
        Form {
            pairedServersSection
            statusSection
            Section {
                TextField("http://192.168.1.20:4096", text: $manualEndpoint)
                    .keyboardType(.URL)
                    .font(codeTypography.swiftUIFont(relativeTo: .footnote))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Server address")

                Toggle("Server uses a password", isOn: $manualRequiresPassword)

                if manualRequiresPassword {
                    SecureField("Password", text: $manualPassword)
                        .font(codeTypography.swiftUIFont(relativeTo: .footnote))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server password")
                }

                TextField("Name (optional)", text: $manualName)
                    .accessibilityLabel("Server name")

                Button("Pair with Server") { pairManually() }
                    .disabled(!canPairManually || isPairing)
            } header: {
                Text("Address and password")
            } footer: {
                Text("Use the address printed by `opencode serve` and the password from `opencode service password`. Leave the password off only for open servers.")
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var pastePayloadPairingPage: some View {
        Form {
            statusSection
            Section {
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first {
                        pastedPayload = value
                    }
                }

                TextEditor(text: $pastedPayload)
                    .frame(minHeight: 120)
                    .font(codeTypography.swiftUIFont(relativeTo: .footnote))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Full pairing setup payload")

                Button("Pair with Setup Payload") {
                    pairFromPastedPayload()
                }
                .disabled(pastedPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPairing)
            } header: {
                Text("One-time pairing payload")
            } footer: {
                Text("Paste the JSON payload copied from your computer. Its kind is aiden-opencode-pairing-v1 and it carries the server address and password.")
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Paste Payload")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pairingStep(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder commands: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(palette.canvas)
                .frame(width: 26, height: 26)
                .background(palette.accent, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondary)
                commands()
            }
        }
    }

    private func commandRow(_ command: String) -> some View {
        Text(command)
            .font(codeTypography.swiftUIFont(relativeTo: .footnote))
            .textSelection(.enabled)
    }

    // MARK: - Rows

    private func installationRow(_ installation: OpenCodeInstallation) -> some View {
        Button {
            Task { await coordinator.switchInstallation(to: installation.id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installation.name)
                        .foregroundStyle(.primary)
                    Text(installation.endpoint.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if installation.id == coordinator.activeInstallationId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Active")
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPairing)
        .accessibilityLabel("\(installation.name), \(installation.endpoint.absoluteString)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                installationPendingRemoval = installation
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var removalDialogTitle: String {
        if let name = installationPendingRemoval?.name {
            return String(localized: "Remove \(name)?")
        }
        return String(localized: "Remove server?")
    }

    /// Payload size ceiling before decoding. QR payloads are inherently small;
    /// pasted text is not — refuse absurd inputs before touching the decoder.
    private static func sanitizedPayloadData(_ raw: String) -> Data? {
        guard !raw.isEmpty, raw.utf8.count <= 65_536 else { return nil }
        return raw.data(using: .utf8)
    }

    // MARK: - Pairing entry points

    private func openScanner() {
        inputProblem = nil
        failure = nil
        isShowingScanner = true
    }

    private func handleScannedPayload(_ raw: String) {
        guard let data = Self.sanitizedPayloadData(raw),
              let payload = try? OpenCodePairingPayload.decode(data) else {
            inputProblem = String(localized:
                "That QR code isn't an OpenCode pairing code."
            )
            return
        }
        runPairing(payload: payload)
    }

    private func pairFromPastedPayload() {
        let raw = pastedPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Self.sanitizedPayloadData(raw),
              let payload = try? OpenCodePairingPayload.decode(data) else {
            inputProblem = String(localized:
                "That text isn't a valid OpenCode pairing payload."
            )
            return
        }
        runPairing(payload: payload)
    }

    private var canPairManually: Bool {
        guard manualEndpointURL != nil else { return false }
        if manualRequiresPassword && manualPassword.isEmpty { return false }
        return true
    }

    private var manualEndpointURL: URL? {
        let trimmed = manualEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), OpenCodeServerConfig.isValidBaseURL(url) else { return nil }
        return url
    }

    private func pairManually() {
        guard let url = manualEndpointURL else { return }
        let config: OpenCodeServerConfig?
        do {
            config = try OpenCodeServerConfig(
                baseURL: url,
                username: OpenCodeServerConfig.defaultUsername,
                password: manualRequiresPassword ? manualPassword : ""
            )
        } catch {
            config = nil
        }
        guard let config else {
            inputProblem = String(localized: "That address isn't a valid server URL.")
            return
        }
        let trimmedName = manualName.trimmingCharacters(in: .whitespacesAndNewlines)
        runPairing(config: config, name: trimmedName.isEmpty ? nil : trimmedName)
    }

    private func runPairing(payload: OpenCodePairingPayload) {
        guard let config = try? payload.serverConfig() else {
            inputProblem = String(localized: "The pairing payload has an invalid address.")
            return
        }
        runPairing(config: config, name: payload.name)
    }

    private func runPairing(config: OpenCodeServerConfig, name: String?) {
        guard !isPairing else { return }
        inputProblem = nil
        failure = nil
        isPairing = true
        Task { @MainActor in
            defer { isPairing = false }
            let result = await coordinator.pair(with: config, name: name)
            switch result {
            case .success:
                pastedPayload = ""
                manualEndpoint = ""
                manualPassword = ""
                manualName = ""
                onPaired?()
                onIntroductionComplete?()
            case .failure(let pairingFailure):
                failure = pairingFailure
            }
        }
    }
}

// MARK: - QR scanner

private struct AidenQRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> AidenQRCodeScannerViewController {
        let controller = AidenQRCodeScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: AidenQRCodeScannerViewController, context: Context) {}
}

private final class AidenQRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var deliveredCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }
    }

    private func requestCameraAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configureSession() }
            }
        default:
            showCameraUnavailable()
        }
    }

    private func configureSession() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            showCameraUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showCameraUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    private func showCameraUnavailable() {
        let label = UILabel()
        label.text = "Camera access is required to scan the pairing QR. You can paste the pairing payload instead."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !deliveredCode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        deliveredCode = true
        session.stopRunning()
        onCode?(value)
    }
}
