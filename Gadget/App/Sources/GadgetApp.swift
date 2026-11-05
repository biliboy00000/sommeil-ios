import SwiftUI

@main
struct GadgetApp: App {
    var body: some Scene {
        WindowGroup {
            GadgetHome()
                .preferredColorScheme(.dark)
        }
    }
}

/// L'accueil : la grille des gadgets. Un gadget s'ouvre en plein écran ; son bouton
/// « grille » (en haut à gauche) ramène ici et l'arrête (caméra, micro, capteurs).
struct GadgetHome: View {
    @State private var open: GadgetEntry?
    @AppStorage("gadget.dernier") private var lastID = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.09, green: 0.08, blue: 0.14)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gadgets")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("\(Catalogue.all.count) dans la boîte")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Catalogue.all) { entry in
                            Button {
                                lastID = entry.id
                                open = entry
                            } label: {
                                GadgetCard(entry: entry, isLast: entry.id == lastID)
                            }
                            .buttonStyle(CardPress())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .fullScreenCover(item: $open) { entry in
            entry.makeView()
                .environment(\.gadgetExit, { open = nil })
        }
    }
}

struct GadgetCard: View {
    let entry: GadgetEntry
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(entry.icon)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .shadow(color: entry.tint.opacity(0.35), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isLast ? entry.tint.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
