import PhotosUI
import SwiftUI
import TeamTasksCore
import UIKit

// « Photo preuve » (docs/CONTRACTS-V3.md §6): the image of a photo (its signed URL, then an in-memory cache by photo
// id, since every signed URL differs), the full-screen viewer, the picker (the photo library, and the camera when the
// device has one) and the encoding of the upload (1600 px on the longest side, JPEG 0.7).

/// The images already shown, by photo id (the signed URLs change at every read, so `URLCache` never hits).
@MainActor
enum TaskPhotoCache {
    private static let images = NSCache<NSString, UIImage>()

    static func image(for photoId: UUID) -> UIImage? {
        images.object(forKey: photoId.uuidString as NSString)
    }

    static func store(_ image: UIImage, for photoId: UUID) {
        images.setObject(image, forKey: photoId.uuidString as NSString)
    }

    static func remove(_ photoId: UUID) {
        images.removeObject(forKey: photoId.uuidString as NSString)
    }
}

/// Reads the bytes behind a photo URL: a `data:` URL (the mock backend) is decoded, any other is downloaded.
enum TaskPhotoLoader {
    static func data(from url: URL) async throws -> Data {
        if url.scheme == "data" {
            let text = url.absoluteString
            guard let comma = text.firstIndex(of: ",") else { throw URLError(.badURL) }
            let header = text[..<comma]
            let payload = String(text[text.index(after: comma)...])
            if header.hasSuffix(";base64") {
                guard let data = Data(base64Encoded: payload) else { throw URLError(.cannotDecodeContentData) }
                return data
            }
            return Data((payload.removingPercentEncoding ?? payload).utf8)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// The image of a photo: a soft placeholder while it loads (a spinner), a symbol when it cannot be shown. The caller
/// names it for VoiceOver (a button's label, or an element of its own).
struct TaskPhotoImage: View {
    let photo: TaskPhoto
    let model: TaskDetailViewModel
    var contentMode: ContentMode

    @State private var image: UIImage?
    @State private var didFail = false

    init(photo: TaskPhoto, model: TaskDetailViewModel, contentMode: ContentMode = .fit) {
        self.photo = photo
        self.model = model
        self.contentMode = contentMode
    }

    var body: some View {
        ZStack {
            if let image = image ?? TaskPhotoCache.image(for: photo.id) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(ColorKey.teal.tone.background)
                    .overlay {
                        if didFail {
                            Image(systemName: "photo")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(ColorKey.teal.tone.foreground)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task(id: photo.id) {
            await load()
        }
    }

    private func load() async {
        if let cached = TaskPhotoCache.image(for: photo.id) {
            image = cached
            return
        }
        guard let url = await model.photoURL(for: photo) else {
            didFail = true
            return
        }
        do {
            let data = try await TaskPhotoLoader.data(from: url)
            guard let decoded = UIImage(data: data) else {
                didFail = true
                return
            }
            TaskPhotoCache.store(decoded, for: photo.id)
            image = decoded
        } catch {
            didFail = !ErrorState.isCancellation(error)
        }
    }
}

/// A photo in full screen, on black: « Fermer », and « Supprimer la photo » (confirmed) for its uploader and the
/// admins. Pinch or double-tap to zoom.
struct TaskPhotoViewer: View {
    let photo: TaskPhoto
    let model: TaskDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDeletion = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1

    init(photo: TaskPhoto, model: TaskDetailViewModel) {
        self.photo = photo
        self.model = model
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            TaskPhotoImage(photo: photo, model: model, contentMode: .fit)
                .scaleEffect(zoom)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(committedZoom * value.magnification, 1), 4)
                        }
                        .onEnded { _ in
                            committedZoom = zoom
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(duration: 0.3)) {
                        zoom = zoom > 1 ? 1 : 2
                        committedZoom = zoom
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel(of: photo))
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(AccessibilityID.Social.photoViewer)
        }
        .overlay(alignment: .top) {
            HStack {
                viewerButton(systemImage: "xmark", label: "Fermer") {
                    dismiss()
                }
                .accessibilityIdentifier(AccessibilityID.Social.photoViewerClose)
                Spacer()
                if model.canDelete(photo) {
                    viewerButton(systemImage: "trash", label: PhotoText.deleteTitle) {
                        isConfirmingDeletion = true
                    }
                    .accessibilityIdentifier(AccessibilityID.Social.photoViewerDelete)
                }
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.top, 8)
        }
        .confirmationDialog(
            "Supprimer cette photo\u{00A0}?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(PhotoText.deleteTitle, role: .destructive) {
                Task {
                    if await model.deletePhoto(photo) {
                        TaskPhotoCache.remove(photo.id)
                        dismiss()
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Elle ne sera plus visible par les membres du groupe.")
        }
        .preferredColorScheme(.dark)
    }

    private func viewerButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Font.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.18), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
    }
}

/// The JPEG of an upload: the longest side brought down to `Limits.photoLongestSide` pixels (`PhotoPixelSize`), the
/// orientation applied, quality `Limits.photoJPEGQuality` (lower when the bytes would pass the bucket's limit).
@MainActor
enum TaskPhotoEncoder {
    static func jpegData(from image: UIImage) -> Data? {
        let pixelWidth = Int((image.size.width * image.scale).rounded())
        let pixelHeight = Int((image.size.height * image.scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let size = PhotoPixelSize.resized(width: pixelWidth, height: pixelHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        for quality in [Limits.photoJPEGQuality, 0.5, 0.35] {
            if let data = resized.jpegData(compressionQuality: CGFloat(quality)), data.count <= Limits.photoBytesMax {
                return data
            }
        }
        return nil
    }
}

/// Where a new photo comes from.
enum TaskPhotoSource: String, Identifiable {
    case library
    case camera

    var id: String { rawValue }

    /// The camera, when the device has one (never in the simulator).
    @MainActor static var isCameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
}

/// The camera (`UIImagePickerController`): hands the photo taken to `onPick`, nil when cancelled.
struct TaskCameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage?) -> Void

    init(onPick: @escaping (UIImage?) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) {
            self.onPick = onPick
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onPick(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}

/// « Ajouter une photo »: the choice between the camera and the library (only the library without a camera), the
/// system picker, then the encoding and the upload through the model.
private struct TaskPhotoPicking: ViewModifier {
    @Binding var isChoosing: Bool
    let model: TaskDetailViewModel

    @State private var source: TaskPhotoSource?
    @State private var isShowingLibrary = false
    @State private var pickedItem: PhotosPickerItem?

    init(isChoosing: Binding<Bool>, model: TaskDetailViewModel) {
        _isChoosing = isChoosing
        self.model = model
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isChoosing) { _, choosing in
                // Without a camera, straight to the library.
                if choosing && !TaskPhotoSource.isCameraAvailable {
                    isChoosing = false
                    isShowingLibrary = true
                }
            }
            .confirmationDialog(
                PhotoText.addTitle,
                isPresented: cameraChoice,
                titleVisibility: .visible
            ) {
                Button(PhotoText.cameraTitle) {
                    source = .camera
                }
                Button(PhotoText.libraryTitle) {
                    isShowingLibrary = true
                }
                Button("Annuler", role: .cancel) {}
            }
            .photosPicker(isPresented: $isShowingLibrary, selection: $pickedItem, matching: .images)
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                pickedItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        model.error = ErrorState(AppError.invalidPhoto)
                        return
                    }
                    await upload(image)
                }
            }
            .fullScreenCover(item: $source) { _ in
                TaskCameraPicker { image in
                    source = nil
                    if let image {
                        Task { await upload(image) }
                    }
                }
                .ignoresSafeArea()
            }
    }

    /// The camera's choice only shows with a camera.
    private var cameraChoice: Binding<Bool> {
        let hasCamera = TaskPhotoSource.isCameraAvailable
        return Binding(
            get: { isChoosing && hasCamera },
            set: { isChoosing = $0 }
        )
    }

    private func upload(_ image: UIImage) async {
        guard let data = TaskPhotoEncoder.jpegData(from: image) else {
            model.error = ErrorState(AppError.invalidPhoto)
            return
        }
        await model.uploadPhoto(jpegData: data)
    }
}

extension View {
    /// « Ajouter une photo » of the task screen: set `isChoosing` to start (camera or library, then the upload).
    func taskPhotoPicking(isChoosing: Binding<Bool>, model: TaskDetailViewModel) -> some View {
        modifier(TaskPhotoPicking(isChoosing: isChoosing, model: model))
    }
}
