import AVKit
import SwiftUI
import UIKit
import FilmCore

/// Une photo ou une vidéo de la pellicule de l'app.
struct GalleryItem: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case photo, video }

    let id: String
    let kind: Kind
    let date: Date
    var duration: Double?
}

/// Les dernières photos et vidéos, gardées dans l'app (Documents/Pellicule) pour les revoir tout de suite.
/// Les originaux sont dans Photos. Les fichiers vidéo ne sont gardés que pour les 3 dernières vidéos.
final class Gallery: ObservableObject {
    static let limit = 30
    static let keptVideos = 3

    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var lastThumbnail: UIImage?

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Pellicule", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    static func newID(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    func imageURL(_ item: GalleryItem) -> URL { directory.appendingPathComponent(item.id + ".heic") }
    func movieURL(_ item: GalleryItem) -> URL { directory.appendingPathComponent(item.id + ".mov") }
    func thumbnailURL(_ item: GalleryItem) -> URL { directory.appendingPathComponent(item.id + ".jpg") }

    /// La vidéo est-elle encore dans l'app (sinon seulement dans Photos) ?
    func hasMovie(_ item: GalleryItem) -> Bool {
        FileManager.default.fileExists(atPath: movieURL(item).path)
    }

    func reload() {
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([GalleryItem].self, from: data) {
            items = saved.filter {
                FileManager.default.fileExists(atPath: thumbnailURL($0).path)
                    || FileManager.default.fileExists(atPath: imageURL($0).path)
            }
        } else {
            // Pellicule d'une version sans index : les photos seulement.
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
            items = files.filter { $0.pathExtension == "heic" }.map { url in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return GalleryItem(id: url.deletingPathExtension().lastPathComponent, kind: .photo, date: date)
            }
            saveIndex()
        }
        items.sort { $0.id > $1.id }
        updateThumbnail()
    }

    /// Écrit les fichiers d'une photo (n'importe quel fil).
    func writePhoto(id: String, date: Date, heif: Data, thumbnail: Data?) throws -> GalleryItem {
        let item = GalleryItem(id: id, kind: .photo, date: date)
        try heif.write(to: imageURL(item), options: .atomic)
        try thumbnail?.write(to: thumbnailURL(item), options: .atomic)
        return item
    }

    /// Déplace une vidéo dans la pellicule (n'importe quel fil).
    func writeVideo(id: String, date: Date, movie: URL, thumbnail: Data?, duration: Double) throws -> GalleryItem {
        let item = GalleryItem(id: id, kind: .video, date: date, duration: duration)
        try? FileManager.default.removeItem(at: movieURL(item))
        try FileManager.default.moveItem(at: movie, to: movieURL(item))
        try thumbnail?.write(to: thumbnailURL(item), options: .atomic)
        return item
    }

    /// Ajoute un élément en tête (fil principal) et ne garde que les plus récents.
    func insert(_ item: GalleryItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        items.sort { $0.id > $1.id }
        while items.count > Self.limit, let last = items.popLast() { deleteFiles(last) }
        // Les vidéos prennent de la place : seules les plus récentes restent dans l'app.
        for (index, video) in items.filter({ $0.kind == .video }).enumerated() where index >= Self.keptVideos {
            try? FileManager.default.removeItem(at: movieURL(video))
        }
        saveIndex()
        updateThumbnail()
    }

    func remove(_ item: GalleryItem) {
        deleteFiles(item)
        items.removeAll { $0.id == item.id }
        saveIndex()
        updateThumbnail()
    }

    private func deleteFiles(_ item: GalleryItem) {
        for url in [imageURL(item), movieURL(item), thumbnailURL(item)] { try? FileManager.default.removeItem(at: url) }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func updateThumbnail() {
        lastThumbnail = items.first.flatMap { UIImage(contentsOfFile: thumbnailURL($0).path) }
    }
}

/// Visionneuse plein écran des dernières photos et vidéos.
struct GalleryViewer: View {
    @ObservedObject var gallery: Gallery
    @Binding var selection: String?
    @Environment(\.dismiss) var dismiss
    @State var chromeVisible = true
    @State var confirmDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if gallery.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 40, weight: .light))
                    Text("Pas encore de photo ni de vidéo")
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.6))
            } else {
                TabView(selection: $selection) {
                    ForEach(gallery.items) { item in
                        page(item)
                            .tag(Optional(item.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            if chromeVisible { chrome }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(.dark)
        .confirmationDialog("Retirer de Ciné ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Retirer de Ciné", role: .destructive) {
                if let current {
                    let next = gallery.items.first { $0.id != current.id }
                    gallery.remove(current)
                    selection = next?.id
                }
            }
        } message: {
            Text("L'original reste dans l'app Photos.")
        }
    }

    @ViewBuilder private func page(_ item: GalleryItem) -> some View {
        switch item.kind {
        case .photo:
            ZoomablePhoto(url: gallery.imageURL(item))
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
        case .video:
            if gallery.hasMovie(item) {
                MoviePage(url: gallery.movieURL(item), active: selection == item.id)
            } else {
                ZStack {
                    ZoomablePhoto(url: gallery.thumbnailURL(item))
                    VStack(spacing: 8) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 30))
                        Text("Cette vidéo est dans l'app Photos.")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
            }
        }
    }

    private var current: GalleryItem? {
        gallery.items.first { $0.id == selection } ?? gallery.items.first
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if let current {
                    HStack(spacing: 6) {
                        if current.kind == .video { Image(systemName: "video.fill") }
                        Text(current.date.formatted(date: .abbreviated, time: .shortened))
                        if let duration = current.duration { Text("· " + Timecode.duration(duration)) }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(current == nil)
            }
            .padding(.horizontal, 16)
            Spacer()
            HStack(spacing: 14) {
                if let current {
                    let url = current.kind == .photo ? gallery.imageURL(current) : gallery.movieURL(current)
                    if current.kind == .photo || gallery.hasMovie(current) {
                        ShareLink(item: url) {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(GlassButtonStyle())
                    }
                }
                Button {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.bottom, 12)
            Text("Tout est aussi dans l'app Photos. Ciné garde les \(Gallery.limit) dernières images et les \(Gallery.keptVideos) dernières vidéos.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
    }
}

/// Lecture d'une vidéo de la pellicule (s'arrête quand on change de page).
struct MoviePage: View {
    let url: URL
    let active: Bool
    @State var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear {
            if player == nil { player = AVPlayer(url: url) }
        }
        .onChange(of: active) { _, isActive in
            if !isActive { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

/// Photo avec zoom (pincer ou double-toucher).
struct ZoomablePhoto: View {
    let url: URL
    @State var image: UIImage?
    @State var scale: CGFloat = 1
    @State var baseScale: CGFloat = 1
    @State var offset: CGSize = .zero
    @State var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .gesture(magnify)
                        .simultaneousGesture(pan, including: scale > 1 ? .all : .none)
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                if scale > 1 {
                                    scale = 1
                                    offset = .zero
                                } else {
                                    scale = 2.5
                                }
                                baseScale = scale
                                baseOffset = offset
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            image = loaded
        }
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = min(max(baseScale * value, 1), 6) }
            .onEnded { _ in
                if scale <= 1.01 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        scale = 1
                        offset = .zero
                    }
                    baseOffset = .zero
                }
                baseScale = scale
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in baseOffset = offset }
    }
}
