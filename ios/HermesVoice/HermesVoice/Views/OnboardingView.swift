import SwiftUI

/// First-launch full-screen onboarding, shown until a backend is configured and
/// a connection test passes (gated by `AppSettings.hasCompletedOnboarding`).
/// Two paths: tap a Bonjour-discovered backend on the LAN, or type a Tailscale
/// MagicDNS hostname / IP. Either way we hit `/health` before saving — so we
/// never drop the user into MainView pointed at an unreachable backend.
struct OnboardingView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var browser = BackendBrowser()

    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var status = ""
    @State private var failed = false

    private var canTest: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !testing
    }

    var body: some View {
        ZStack {
            HVColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    discoveredSection
                    manualSection
                    testButton
                    if !status.isEmpty { statusView }
                }
                .padding(24)
                .padding(.top, 20)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
        .tint(HVColor.amber)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.resolvedURL) { _, newURL in
            // A discovered backend resolved → prefill the field; user confirms
            // (and adds a token if needed) before we test.
            if let newURL {
                url = newURL.absoluteString
                status = ""
                failed = false
            }
        }
        .onChange(of: browser.resolveError) { _, err in
            // Surface a failed Bonjour resolve instead of leaving the row
            // spinning silently.
            if let err, !err.isEmpty {
                status = err
                failed = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(HVColor.amber)
            Text("HERMES VOICE")
                .font(HVFont.title)
                .tracking(1.0)
                .foregroundStyle(HVColor.amber)
            Text("Connect to your self-hosted backend to get started.")
                .font(HVFont.body)
                .foregroundStyle(HVColor.creamDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ON YOUR NETWORK")
            if browser.results.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(HVColor.bronze)
                    Text("Searching the local network…")
                        .font(HVFont.captionTiny)
                        .foregroundStyle(HVColor.creamDim)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(browser.results) { backend in
                    discoveredRow(backend)
                }
            }
            Text("Bonjour finds your Mac only on the same Wi-Fi. Over Tailscale, enter the MagicDNS hostname below.")
                .font(HVFont.micro)
                .foregroundStyle(HVColor.creamFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func discoveredRow(_ backend: DiscoveredBackend) -> some View {
        Button {
            browser.resolve(backend)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(HVColor.bronze)
                VStack(alignment: .leading, spacing: 1) {
                    Text(backend.name)
                        .font(HVFont.body)
                        .foregroundStyle(HVColor.cream)
                    if let host = backend.txt["host"], !host.isEmpty {
                        Text(host)
                            .font(HVFont.micro)
                            .foregroundStyle(HVColor.creamDim)
                    }
                }
                Spacer(minLength: 0)
                if browser.isResolving {
                    ProgressView().tint(HVColor.amber)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(HVColor.amber)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(HVColor.creamSurface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HVColor.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("OR ENTER MANUALLY")
            OnboardField(label: "URL", value: $url, placeholder: "https://name.ts.net:8765")
            OnboardField(label: "Token", value: $token, placeholder: "(optional)", secure: true)
        }
    }

    private var testButton: some View {
        Button {
            Task { await testConnection() }
        } label: {
            HStack {
                Spacer()
                if testing {
                    ProgressView().tint(HVColor.bg)
                } else {
                    Text("Test & Continue")
                        .font(HVFont.body.weight(.semibold))
                        .foregroundStyle(HVColor.bg)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 12).fill(HVColor.amber))
        }
        .buttonStyle(.plain)
        .disabled(!canTest)
        .opacity(canTest ? 1 : 0.5)
    }

    private var statusView: some View {
        Text(status)
            .font(HVFont.captionTiny)
            .foregroundStyle(failed ? HVColor.danger : HVColor.creamDim)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(HVFont.captionTiny.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(HVColor.bronze)
    }

    private func testConnection() async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testing = true
        failed = false
        status = "Testing…"
        defer { testing = false }
        let api = HermesVoiceAPI(baseURL: trimmed, authToken: token)
        do {
            _ = try await api.health()
            settings.backendURL = trimmed
            settings.authToken = token
            settings.markReachable()
            // Flips HermesVoiceApp from OnboardingView to MainView.
            settings.hasCompletedOnboarding = true
        } catch {
            status = "Couldn't reach backend: \(error.localizedDescription)"
            failed = true
        }
    }
}

private struct OnboardField: View {
    let label: String
    @Binding var value: String
    var placeholder: String = ""
    var secure: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(HVFont.bodyDim)
                .foregroundStyle(HVColor.creamDim)
                .frame(width: 56, alignment: .leading)
            Group {
                if secure {
                    SecureField(placeholder, text: $value)
                } else {
                    TextField(placeholder, text: $value)
                        .keyboardType(.URL)
                }
            }
            .font(HVFont.body)
            .foregroundStyle(HVColor.cream)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(HVColor.creamSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HVColor.hairline, lineWidth: 0.5))
    }
}
