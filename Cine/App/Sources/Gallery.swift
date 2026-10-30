import SwiftUI
import UIKit

struct GalleryItem: Identifiable, Hashable {
    let id: String
    let imageURL: URL
    let thumbnailURL: URL
    let date: Date
}

/// Les dernières photos développées, gardées dans l'app (Documents/Pellicule) pour les revoir tout de suite.
/// Les originaux sont dans Photos.
final class Gallery: ObservableObject {
    static let limit = 30

    @Published private(set) var items: [GalleryItem] = []
    @Published private(set) var lastThumbnail: UIImage?

    let directory: URL

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

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        items = files.filter { $0.pathExtension == "heic" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                return GalleryItem(id: id, imageURL: url, thumbnailURL: directory.appendingPathComponent(id + ".jpg"), date: date)
            }
        lastThumbnail = items.first.flatMap { UIImage(contentsOfFile: $0.thumbnailURL.path) }
    }

    /// Écrit les fichiers (n'importe quel fil).
    func write(id: String, date: Date, heif: Data, thumbnail: Data?) throws -> GalleryItem {
        let image = directory.appendingPathComponent(id + ".heic")
        let thumb = directory.appendingPathComponent(id + ".jpg")
        try heif.write(to: image, options: .atomic)
        try thumbnail?.write(to: thumb, options: .atomic)
        return GalleryItem(id: id, imageURL: image, thumbnailURL: thumb, date: date)
    }

    /// Ajoute une photo en tête (fil principal) et ne garde que les plus récentes.
    func insert(_ item: GalleryItem) {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        items.sort { $0.id > $1.id }
        while items.count > Self.limit, let last = items.popLast() {
            try? FileManager.default.removeItem(at: last.imageURL)
            try? FileManager.default.removeItem(at: last.thumbnailURL)
        }
        lastThumbnail = items.first.flatMap { UIImage(contentsOfFile: $0.thumbnailURL.path) }
    }

    func remove(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: item.imageURL)
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        items.removeAll { $0.id == item.id }
        lastThumbnail = items.first.flatMap { UIImage(contentsOfFile: $0.thumbnailURL.path) }
    }
}

/// Visionneuse plein écran des dernières photos.
struct GalleryViewer: View {
    @ObservedObject var gallery: Gallery
    @Binding var selection: String?
    @Environment(\.dismiss) var dismiss
    @State var chromeVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if gallery.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 40, weight: .light))
                    Text("Pas encore de photo")
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.6))
            } else {
                TabView(selection: $selection) {
                    ForEach(gallery.items) { item in
                        ZoomablePhoto(url: item.imageURL)
                            .tag(Optional(item.id))
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            if chromeVisible { chrome }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(.dark)
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
                    Text(current.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)
            Spacer()
            HStack(spacing: 14) {
                if let current {
                    ShareLink(item: current.imageURL) {
                        Label("Partager", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                Button {
                    if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.bottom, 12)
            Text("Les photos sont aussi dans l'app Photos. Ciné garde les \(Gallery.limit) dernières.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .transition(.opacity)
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
