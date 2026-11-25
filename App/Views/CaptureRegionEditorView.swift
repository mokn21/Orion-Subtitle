import CoreImage
import SwiftUI
import UIKit

struct CaptureRegionEditorView: View {
    let pixelBuffer: CVPixelBuffer?
    @Binding var region: CaptureRegion
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CaptureRegion
    @State private var zoom: Double = 1
    @State private var previewOffset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var moveStart: CaptureRegion?
    @State private var resizeStart: CaptureRegion?

    init(pixelBuffer: CVPixelBuffer?, region: Binding<CaptureRegion>) {
        self.pixelBuffer = pixelBuffer
        self._region = region
        self._draft = State(initialValue: region.wrappedValue.clamped)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geo in
                    let canvas = fittedCanvas(in: geo.size)
                    ZStack {
                        preview
                            .frame(width: canvas.width, height: canvas.height)
                            .clipped()
                        regionOverlay(canvas: canvas)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal)

                VStack(spacing: 8) {
                    labeledSlider(title: "تكبير المعاينة", value: $zoom, range: 0.5...2.0, label: String(format: "%.0f%%", zoom * 100))
                    labeledSlider(title: "العرض", value: $draft.width, range: 0.05...1, label: String(format: "%.0f%%", draft.width * 100))
                    labeledSlider(title: "الارتفاع", value: $draft.height, range: 0.05...1, label: String(format: "%.0f%%", draft.height * 100))
                }
                .padding(.horizontal)
                HStack {
                    Text("حرّك الصورة بإصبعك، واسحب المربع الأزرق لتغيير مكان الالتقاط")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("إعادة ضبط") {
                        zoom = 1
                        previewOffset = .zero
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("منطقة OCR")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { region = draft.clamped; dismiss() }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
        .preferredColorScheme(.dark)
    }

    private var preview: some View {
        Group {
            if let image = makeImage(from: pixelBuffer) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(previewOffset)
                    .gesture(previewPanGesture())
            } else {
                ZStack {
                    Color(white: 0.08)
                    Text("بانتظار أول إطار من Remote Play")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func regionOverlay(canvas: CGSize) -> some View {
        let r = draft.clamped
        let width = canvas.width * r.width
        let height = canvas.height * r.height
        let origin = CGPoint(x: canvas.width * r.x, y: canvas.height * (1 - r.y - r.height))
        return RoundedRectangle(cornerRadius: 4)
            .stroke(Color.cyan, lineWidth: 3)
            .frame(width: width, height: height)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(.white).frame(width: 22, height: 22)
                    .contentShape(Circle())
                    .highPriorityGesture(resizeGesture(canvas: canvas))
            }
            .position(x: origin.x + width / 2, y: origin.y + height / 2)
            .contentShape(Rectangle())
            .gesture(moveGesture(canvas: canvas))
            .overlay(alignment: .topLeading) {
                Text("اسحب المربع الأزرق")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.65), in: Capsule())
                    .offset(x: 6, y: 6)
                    .allowsHitTesting(false)
            }
    }

    private func moveGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            if moveStart == nil { moveStart = draft.clamped }
            guard let start = moveStart else { return }
            draft.x = min(max(start.x + value.translation.width / canvas.width, 0), 1 - start.width)
            draft.y = min(max(start.y - value.translation.height / canvas.height, 0), 1 - start.height)
        }.onEnded { _ in
            moveStart = nil
        }
    }

    private func resizeGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            if resizeStart == nil { resizeStart = draft.clamped }
            guard let start = resizeStart else { return }
            draft.width = min(max(start.width + value.translation.width / canvas.width, 0.05), 1 - start.x)
            draft.height = min(max(start.height - value.translation.height / canvas.height, 0.05), 1 - start.y)
        }.onEnded { _ in
            resizeStart = nil
        }
    }

    private func previewPanGesture() -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil { panStart = previewOffset }
                guard let panStart else { return }
                previewOffset = CGSize(
                    width: panStart.width + value.translation.width,
                    height: panStart.height + value.translation.height
                )
            }
            .onEnded { _ in panStart = nil }
    }

    private func labeledSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(label).foregroundStyle(.secondary) }
            Slider(value: value, in: range)
        }
    }

    private func fittedCanvas(in size: CGSize) -> CGSize {
        let aspect: CGFloat = 16 / 9
        let width = min(size.width, size.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func makeImage(from buffer: CVPixelBuffer?) -> UIImage? {
        guard let buffer else { return nil }
        let context = CIContext()
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
