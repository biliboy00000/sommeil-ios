import SwiftUI
import SleepCore

/// Racine de l'app : quatre onglets, l'écran de nuit en plein écran, la feuille « Démarrer la nuit ? ».
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder

    var body: some View {
        TabView(selection: $model.tab) {
            TonightView()
                .tabItem { Label("Ce soir", systemImage: "moon.stars.fill") }
                .tag(AppTab.tonight)
            HeartView()
                .tabItem { Label("Cœur", systemImage: "heart.fill") }
                .tag(AppTab.heart)
            NightsView()
                .tabItem { Label("Nuits", systemImage: "calendar") }
                .tag(AppTab.nights)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.indigo)
        .fullScreenCover(isPresented: Binding(get: { recorder.isRecording || recorder.isWaiting }, set: { _ in })) {
            RecordingView()
        }
        .alert(item: $model.alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .sheet(item: $model.startSheet, onDismiss: { model.performQueuedStart() }) { request in
            StartNightSheet(request: request)
        }
        .onAppear {
            model.refresh()
            model.runPendingReminder()
        }
    }
}

/// Onglet « Ce soir » : tout pour lancer la nuit, en un coup d'œil.
struct TonightView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: AppSettings

    @State private var showRenewal = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !model.interruptedSessions.isEmpty {
                        interruptedBanner
                    }
                    NightHeroCard()
                    HStack(spacing: 10) {
                        batteryTile
                        Button { showRenewal = true } label: { installationTile }
                            .buttonStyle(PressableStyle())
                        storageTile
                    }
                    if let last = model.sessions.first(where: \.isNight) ?? model.sessions.first {
                        NavigationLink {
                            SessionDetailView(item: last)
                        } label: {
                            LastSessionCard(item: last)
                        }
                        .buttonStyle(PressableStyle())
                    }
                    toolsSection
                    Text(Texts.medical)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ce soir")
            .refreshable { model.refresh() }
            .sheet(isPresented: $showRenewal) { RenewalSheet() }
        }
    }

    // MARK: - Tuiles

    private var batteryTile: some View {
        let forecast = model.batteryForecast
        let level = model.batteryLevel.map(\.percentText) ?? "?"
        let tint: Color
        switch forecast.verdict {
        case .insuffisant: tint = .red
        case .juste: tint = .orange
        default: tint = .green
        }
        let detail = forecast.predicted.map { "≈ \(max(0, $0).percentText) au réveil" } ?? "conso. à mesurer"
        return StatTile(icon: "battery.75percent", tint: tint, title: "Batterie", value: level, detail: detail)
    }

    private var installationTile: some View {
        let days = model.installation?.daysRemaining()
        let value = days.map { $0 >= 1 ? "\(Int($0.rounded(.down))) j" : "\(max(0, Int(($0 * 24).rounded(.down)))) h" } ?? "?"
        let tint: Color = (days ?? 7) < 1 ? .red : ((days ?? 7) < 2 ? .orange : .blue)
        return StatTile(icon: "arrow.triangle.2.circlepath", tint: tint, title: "Installation", value: value,
                        detail: "SideStore")
            .foregroundStyle(.primary)
    }

    private var storageTile: some View {
        let free = DeviceInfo.freeDiskMB
        let value = free.map { String(format: "%.0f Go", $0 / 1000) } ?? "?"
        let tint: Color = (free ?? 10_000) < 3000 ? .red : .gray
        return StatTile(icon: "internaldrive", tint: tint, title: "Stockage", value: value, detail: "libre")
    }

    // MARK: - Sections

    private var interruptedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Enregistrement interrompu", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.interruptedSessions, id: \.self) { url in
                if let item = model.sessions.first(where: { $0.url == url }) {
                    NavigationLink {
                        SessionDetailView(item: item)
                    } label: {
                        HStack {
                            Text(item.summary?.endExplanation ?? item.title)
                                .font(.subheadline)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("J'ai compris") {
                withAnimation(.snappy) { model.interruptedSessions = [] }
            }
            .font(.subheadline.weight(.semibold))
        }
        .card()
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Outils")
                .font(.title3.weight(.semibold))
                .padding(.top, 6)
            Button {
                withAnimation(.snappy) { model.tab = .heart }
            } label: {
                ToolRow(icon: "heart.fill", tint: Palette.heart, title: "Cœur en direct",
                        subtitle: "Pose le téléphone sur ta poitrine et regarde ton cœur battre.")
            }
            .buttonStyle(PressableStyle())
            Button {
                recorder.start(kind: .guided) { error in
                    if let error { model.alert = AlertMessage(title: "Impossible de démarrer", message: error) }
                }
            } label: {
                ToolRow(icon: "list.number", tint: .teal, title: "Test guidé de 10 minutes",
                        subtitle: "Une voix te guide : sur le dos, mouvements, côtés, deux arrêts de respiration.")
            }
            .buttonStyle(PressableStyle())
        }
    }
}

/// Grande carte de nuit : réveil prévu, batterie au réveil, bouton « Commencer la nuit ».
struct NightHeroCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var taps = 0

    var body: some View {
        let forecast = model.batteryForecast
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dayText(Date()))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Prêt pour la nuit ?")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Palette.moon)
                    .symbolEffect(.pulse.byLayer, options: .repeating.speed(0.3))
            }
            HStack(spacing: 20) {
                heroValue(icon: "alarm", label: "Réveil", value: clockText(forecast.wake))
                if let predicted = forecast.predicted {
                    heroValue(icon: "battery.50percent", label: "Batterie au réveil",
                              value: "≈ \(max(0, predicted).percentText)")
                }
            }
            Button {
                taps += 1
                model.presentStartSheet()
            } label: {
                Label("Commencer la nuit", systemImage: "moon.zzz.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.nightTop)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        }
        .padding(20)
        .background {
            ZStack {
                LinearGradient(colors: [Palette.nightTop, Palette.nightBottom], startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Starfield(count: 28)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .shadow(color: Palette.nightBottom.opacity(0.35), radius: 18, y: 8)
    }

    private func heroValue(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}

/// Carte « Dernière nuit ».
struct LastSessionCard: View {
    let item: SessionItem

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ProgressRing(progress: item.summary?.sensorCoverage ?? 0, lineWidth: 6,
                             tint: (item.summary?.endedNormally ?? true) ? .green : .orange)
                Image(systemName: item.isNight ? "moon.fill" : "list.number")
                    .font(.headline)
                    .foregroundStyle(.indigo)
            }
            .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.isNight ? "Dernière nuit" : "Dernier enregistrement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.summary.map { TimeText.duration($0.duration) } ?? "—")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text(item.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let summary = item.summary {
                    Text("capteurs \(summary.sensorCoverage.percentText)")
                    Text("son \(summary.audioCoverage.percentText)")
                    if !summary.endedNormally {
                        Text("interrompu").foregroundStyle(.orange)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .card()
    }
}

struct ToolRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .card(padding: 14)
    }
}

/// Feuille « Renouveler l'installation » (SideStore, tous les 7 jours, sans ordinateur).
struct RenewalSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let expiry = model.installation?.expiration {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Valable jusqu'au").font(.subheadline).foregroundStyle(.secondary)
                            Text(expiry.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                                .font(.title2.weight(.semibold))
                        }
                    }
                    Text("Avec un identifiant Apple gratuit, Apple limite l'installation à 7 jours. SideStore la "
                         + "renouvelle depuis l'iPhone, sans ordinateur :")
                        .font(.subheadline)
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Ouvre l'app LocalDevVPN et touche « Connect ».")
                        step(2, "Ouvre SideStore, onglet « My Apps ».")
                        step(3, "Touche « Refresh All » (ou le bouton « 7 DAYS » à côté de Sommeil).")
                        step(4, "Tu peux ensuite déconnecter LocalDevVPN.")
                    }
                    Text("Astuce : une automatisation Raccourcis (tous les jours, par exemple à midi) peut le faire "
                         + "toute seule. L'app te prévient aussi avant une nuit si l'installation expire avant ton réveil.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        if let url = URL(string: "sidestore://") {
                            openURL(url) { accepted in openFailed = !accepted }
                        }
                    } label: {
                        Label("Ouvrir SideStore", systemImage: "arrow.up.forward.app")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .prominentButton()
                    if openFailed {
                        Text("SideStore ne s'ouvre pas d'ici : ouvre-le depuis l'écran d'accueil.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
            .navigationTitle("Renouveler l'installation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.indigo, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
