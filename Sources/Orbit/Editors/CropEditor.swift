import SwiftUI

struct CropEditor: View {
    let url: URL
    let image: CGImage
    let close: () -> Void

    private let preview: CGImage
    private let imageSize: CGSize

    @State private var crop: CGRect
    @State private var aspect: Aspect = .free
    @State private var widthInput = 0
    @State private var heightInput = 0
    @State private var dragHandle: Handle?
    @State private var dragStart: CGRect = .zero

    init(url: URL, image: CGImage, close: @escaping () -> Void) {
        self.url = url
        self.image = image
        self.close = close
        preview = ImageIOUtil.downscale(image, maxDimension: 1400) ?? image
        imageSize = image.size
        _crop = State(initialValue: CGRect(origin: .zero, size: image.size))
    }

    enum Aspect: Hashable, CaseIterable {
        case free, square, wide, tall, classic, portrait
        var label: String {
            switch self {
            case .free: "Free"
            case .square: "1:1"
            case .wide: "16:9"
            case .tall: "9:16"
            case .classic: "4:3"
            case .portrait: "3:4"
            }
        }
        var ratio: CGFloat? {
            switch self {
            case .free: nil
            case .square: 1
            case .wide: 16.0 / 9
            case .tall: 9.0 / 16
            case .classic: 4.0 / 3
            case .portrait: 3.0 / 4
            }
        }
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
        var left: Bool { [.topLeft, .bottomLeft, .left].contains(self) }
        var right: Bool { [.topRight, .bottomRight, .right].contains(self) }
        var top: Bool { [.topLeft, .top, .topRight].contains(self) }
        var bottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (left || right) && (top || bottom) }

        func point(in r: CGRect) -> CGPoint {
            CGPoint(x: left ? r.minX : right ? r.maxX : r.midX, y: top ? r.minY : bottom ? r.maxY : r.midY)
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            PreviewWell {
                GeometryReader { geo in
                    let fit = fitRect(imageSize, in: geo.size)
                    let s = fit.width / max(imageSize.width, 1)
                    let disp = CGRect(x: fit.minX + crop.minX * s, y: fit.minY + crop.minY * s,
                                      width: crop.width * s, height: crop.height * s)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .offset(x: fit.minX, y: fit.minY)

                        Path { p in
                            p.addRect(fit)
                            p.addRect(disp)
                        }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

                        if dragHandle != nil {
                            Path { p in
                                for i in 1...2 {
                                    let x = disp.minX + disp.width * CGFloat(i) / 3
                                    let y = disp.minY + disp.height * CGFloat(i) / 3
                                    p.move(to: CGPoint(x: x, y: disp.minY)); p.addLine(to: CGPoint(x: x, y: disp.maxY))
                                    p.move(to: CGPoint(x: disp.minX, y: y)); p.addLine(to: CGPoint(x: disp.maxX, y: y))
                                }
                            }
                            .stroke(.white.opacity(0.6), lineWidth: 0.5)
                        }

                        Rectangle()
                            .stroke(Theme.accent, lineWidth: 2)
                            .frame(width: disp.width, height: disp.height)
                            .offset(x: disp.minX, y: disp.minY)

                        ForEach(Handle.allCases.filter { $0 != .move }, id: \.self) { handle in
                            let p = handle.point(in: disp)
                            let horizontalBar = !handle.isCorner && (handle.top || handle.bottom)
                            let verticalBar = !handle.isCorner && (handle.left || handle.right)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.accent)
                                .frame(width: horizontalBar ? 22 : verticalBar ? 5 : 11,
                                       height: verticalBar ? 22 : horizontalBar ? 5 : 11)
                                .shadow(color: .black.opacity(0.25), radius: 2)
                                .position(p)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if dragHandle == nil {
                                    dragHandle = hitHandle(value.startLocation, in: disp)
                                    dragStart = crop
                                }
                                guard let handle = dragHandle, s > 0 else { return }
                                crop = resize(dragStart, handle, value.translation.width / s, value.translation.height / s)
                            }
                            .onEnded { _ in dragHandle = nil }
                    )
                }
            }

            VStack(spacing: 14) {
                ControlRow(label: "Aspect ratio") {
                    PillPicker(options: Aspect.allCases.map { ($0, $0.label) }, selection: $aspect)
                    Spacer(minLength: 0)
                }
                ControlRow(label: "") {
                    HStack(spacing: 8) {
                        dimensionField("W", value: $widthInput) { setSize(width: CGFloat(widthInput), height: nil) }
                        dimensionField("H", value: $heightInput) { setSize(width: nil, height: CGFloat(heightInput)) }
                        Text("px").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Button("Reset") {
                    withAnimation(.snappy) { aspect = .free; crop = CGRect(origin: .zero, size: imageSize) }
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button("Apply") { apply() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .onAppear(perform: syncFields)
        .onChange(of: crop) { syncFields() }
        .onChange(of: aspect) { applyAspect() }
    }

    private func dimensionField(_ label: String, value: Binding<Int>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink.opacity(0.6))
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 13).monospacedDigit())
                .padding(.horizontal, 8)
                .frame(width: 70, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.7)))
                .onSubmit(commit)
        }
    }

    private func syncFields() {
        widthInput = Int(crop.width.rounded())
        heightInput = Int(crop.height.rounded())
    }

    private func hitHandle(_ p: CGPoint, in disp: CGRect) -> Handle? {
        let candidates = Handle.allCases.filter { $0 != .move }
        if let nearest = candidates.min(by: { dist($0.point(in: disp), p) < dist($1.point(in: disp), p) }),
           dist(nearest.point(in: disp), p) < 18 {
            return nearest
        }
        return disp.contains(p) ? .move : nil
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func resize(_ s: CGRect, _ h: Handle, _ dx: CGFloat, _ dy: CGFloat) -> CGRect {
        let W = imageSize.width, H = imageSize.height
        let minSide: CGFloat = 16
        if h == .move {
            var r = s.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(0, r.minX), W - r.width)
            r.origin.y = min(max(0, r.minY), H - r.height)
            return r
        }
        var x0 = s.minX, x1 = s.maxX, y0 = s.minY, y1 = s.maxY
        if h.left { x0 = min(max(0, x0 + dx), x1 - minSide) }
        if h.right { x1 = max(min(W, x1 + dx), x0 + minSide) }
        if h.top { y0 = min(max(0, y0 + dy), y1 - minSide) }
        if h.bottom { y1 = max(min(H, y1 + dy), y0 + minSide) }
        guard let ratio = aspect.ratio else { return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }

        var w = x1 - x0, ht = y1 - y0
        if h.isCorner {
            if abs(dx) >= abs(dy) { ht = w / ratio } else { w = ht * ratio }
            let maxW = h.left ? s.maxX : W - s.minX
            let maxH = h.top ? s.maxY : H - s.minY
            if w > maxW { w = maxW; ht = w / ratio }
            if ht > maxH { ht = maxH; w = ht * ratio }
            x0 = h.left ? s.maxX - w : s.minX
            y0 = h.top ? s.maxY - ht : s.minY
        } else if h.left || h.right {
            ht = w / ratio
            if ht > H { ht = H; w = ht * ratio }
            x0 = h.left ? s.maxX - w : s.minX
            y0 = min(max(0, s.midY - ht / 2), H - ht)
        } else {
            w = ht * ratio
            if w > W { w = W; ht = w / ratio }
            y0 = h.top ? s.maxY - ht : s.minY
            x0 = min(max(0, s.midX - w / 2), W - w)
        }
        return CGRect(x: x0, y: y0, width: w, height: ht)
    }

    private func applyAspect() {
        guard let r = aspect.ratio else { return }
        let W = imageSize.width, H = imageSize.height
        var w = W, h = W / r
        if h > H { h = H; w = H * r }
        withAnimation(.snappy(duration: 0.25)) {
            crop = CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)
        }
    }

    private func setSize(width: CGFloat?, height: CGFloat?) {
        let W = imageSize.width, H = imageSize.height
        var w = min(max(16, width ?? crop.width), W)
        var h = min(max(16, height ?? crop.height), H)
        if let r = aspect.ratio {
            if width != nil { h = w / r } else { w = h * r }
            if w > W { w = W; h = w / r }
            if h > H { h = H; w = h * r }
        }
        let x = min(max(0, crop.midX - w / 2), W - w)
        let y = min(max(0, crop.midY - h / 2), H - h)
        withAnimation(.snappy(duration: 0.25)) { crop = CGRect(x: x, y: y, width: w, height: h) }
    }

    private func apply() {
        let rect = crop.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard let cropped = image.cropping(to: rect) else { return }
        Editors.save(cropped, from: url, suffix: "Cropped", close: close)
    }
}
