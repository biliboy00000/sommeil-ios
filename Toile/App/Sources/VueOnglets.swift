import SwiftUI

/// Tous les onglets, normaux ou privés.
struct VueOnglets: View {
    @ObservedObject private var navigateur = Navigateur.shared
    @State private var prive = Navigateur.shared.actif?.prive ?? false
    @State private var confirmerFermeture = false
    private let colonnes = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private var liste: [Onglet] {
        navigateur.onglets.filter { $0.prive == prive }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if liste.isEmpty {
                    ContentUnavailableView {
                        Label(prive ? "Aucun onglet privé" : "Aucun onglet", systemImage: prive ? "hand.raised" : "square.on.square")
                    } description: {
                        Text(prive ? "Un onglet privé ne garde ni historique ni cookies : tout s'efface quand tu fermes le dernier."
                                   : "Touche + pour ouvrir un onglet.")
                    }
                    .padding(.top, 80)
                }
                LazyVGrid(columns: colonnes, spacing: 16) {
                    ForEach(liste) { onglet in
                        CarteOnglet(onglet: onglet, actif: onglet.id == navigateur.actif?.id) {
                            navigateur.selectionner(onglet)
                        } fermer: {
                            withAnimation(.snappy) { navigateur.fermer(onglet) }
                        }
                    }
                }
                .padding(14)
            }
            .background(prive ? Color(red: 0.08, green: 0.06, blue: 0.12) : Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Genre d'onglets", selection: $prive) {
                        Text("Onglets").tag(false)
                        Text("Privés").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("OK") { terminer() }.bold()
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Tout fermer", role: .destructive) { confirmerFermeture = true }
                        .disabled(liste.isEmpty)
                    Spacer()
                    Button {
                        navigateur.nouvelOnglet(prive: prive)
                    } label: {
                        Image(systemName: "plus").font(.title3.weight(.semibold))
                    }
                    .accessibilityLabel(prive ? "Nouvel onglet privé" : "Nouvel onglet")
                }
            }
            .confirmationDialog(prive ? "Fermer tous les onglets privés ?" : "Fermer tous les onglets ?",
                                isPresented: $confirmerFermeture, titleVisibility: .visible) {
                Button("Fermer \(liste.count) onglet\(liste.count > 1 ? "s" : "")", role: .destructive) {
                    navigateur.fermerTout(prive: prive)
                }
            }
        }
        .preferredColorScheme(prive ? .dark : nil)
    }

    /// « OK » : reste sur l'onglet actif s'il est du genre affiché, sinon ouvre le dernier de ce genre.
    private func terminer() {
        if let actif = navigateur.actif, actif.prive != prive, let dernier = liste.last {
            navigateur.selectionner(dernier)
        } else {
            navigateur.afficherOnglets = false
        }
    }
}

struct CarteOnglet: View {
    @ObservedObject var onglet: Onglet
    let actif: Bool
    let ouvrir: () -> Void
    let fermer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = onglet.apercu {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(.secondarySystemBackground)
                            if let url = onglet.adresse {
                                Pastille(texte: onglet.titre, url: url, taille: 54)
                            } else {
                                Image(systemName: onglet.prive ? "hand.raised" : "plus")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 200, alignment: .top)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(actif ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: actif ? 3 : 1)
                )
                Button(action: fermer) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .accessibilityLabel("Fermer l'onglet")
            }
            Text(nom)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: ouvrir)
    }

    private var nom: String {
        if !onglet.titre.isEmpty { return onglet.titre }
        if let hote = onglet.adresse?.host { return Navigateur.domaine(hote) }
        return onglet.prive ? "Onglet privé" : "Nouvel onglet"
    }
}
