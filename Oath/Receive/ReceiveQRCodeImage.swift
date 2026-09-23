import SwiftUI

struct ReceiveQRCodeImage: View {
    let payload: String
    let contentPadding: CGFloat
    let accessibilityLabel: LocalizedStringKey
    let showsBrandMark: Bool
    let cachesRenderedImage: Bool
    let animatesReveal: Bool
    let animatesPayloadReplacement: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var renderedImage: CGImage?
    @State private var renderedPayload: String
    @State private var didFail = false

    init(
        payload: String,
        contentPadding: CGFloat = 16,
        accessibilityLabel: LocalizedStringKey =
            "receive.qr.accessibility",
        showsBrandMark: Bool = false,
        cachesRenderedImage: Bool = true,
        animatesReveal: Bool = false,
        animatesPayloadReplacement: Bool = false
    ) {
        self.payload = payload
        self.contentPadding = contentPadding
        self.accessibilityLabel = accessibilityLabel
        self.showsBrandMark = showsBrandMark
        self.cachesRenderedImage = cachesRenderedImage
        self.animatesReveal = animatesReveal
        self.animatesPayloadReplacement = animatesPayloadReplacement
        _renderedPayload = State(initialValue: payload)
        _renderedImage = State(
            initialValue: cachesRenderedImage
                ? ReceiveQRCodeMemoryCache.shared.image(for: payload)
                : nil
        )
    }

    var body: some View {
        ZStack {
            if let renderedImage,
               animatesPayloadReplacement || renderedPayload == payload {
                let image = ReceiveQRCodeAppearance.image(renderedImage, colorScheme: colorScheme)
                Group {
                    if animatesReveal {
                        ReceiveQRCodeRevealView(
                            image: image,
                            payload: renderedPayload,
                            reduceMotion: reduceMotion,
                            isSceneActive: scenePhase == .active
                        )
                    } else {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(image.shouldInterpolate ? .high : .none)
                            .scaledToFit()
                    }
                }
                .overlay {
                    if showsBrandMark {
                        ReceiveQRCodeBrandMark()
                    }
                }
                .padding(contentPadding)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityAddTraits(.isImage)
                .id(renderedPayload)
                .transition(payloadReplacementTransition)
            } else if renderedPayload == payload, didFail {
                Text("receive.qr.unavailable")
                    .font(.footnote)
                    .foregroundStyle(WalletTheme.qrCodeInk)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Color.clear
                    .accessibilityLabel(
                        Text("receive.details.loading")
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .transaction {
            if !animatesPayloadReplacement {
                $0.animation = nil
            }
        }
        .task(id: payload) {
            await loadQRCode()
        }
    }

    @MainActor
    private func loadQRCode() async {
        if renderedPayload == payload, renderedImage != nil { return }
        let requestedPayload = payload
        if cachesRenderedImage,
           let cachedImage =
            ReceiveQRCodeMemoryCache.shared.image(for: requestedPayload) {
            publish(cachedImage, for: requestedPayload)
            return
        }

        if !animatesPayloadReplacement {
            renderedImage = nil
            renderedPayload = requestedPayload
        }
        didFail = false
        let image = await ReceiveQRCodeRenderer.shared.image(
            for: requestedPayload,
            cacheResult: cachesRenderedImage
        )
        guard !Task.isCancelled,
              requestedPayload == payload else { return }
        if let image {
            publish(image, for: requestedPayload)
        } else {
            publishFailure(for: requestedPayload)
        }
    }

    @MainActor
    private func publish(_ image: CGImage, for payload: String) {
        let shouldAnimate = animatesPayloadReplacement
            && renderedImage != nil
            && renderedPayload != payload
            && !reduceMotion
        if shouldAnimate {
            withAnimation(.smooth(duration: 0.28)) {
                renderedImage = image
                renderedPayload = payload
                didFail = false
            }
        } else {
            renderedImage = image
            renderedPayload = payload
            didFail = false
        }
    }

    @MainActor
    private func publishFailure(for payload: String) {
        if animatesPayloadReplacement,
           renderedImage != nil,
           !reduceMotion {
            withAnimation(.smooth(duration: 0.28)) {
                renderedImage = nil
                renderedPayload = payload
                didFail = true
            }
        } else {
            renderedImage = nil
            renderedPayload = payload
            didFail = true
        }
    }

    private var payloadReplacementTransition: AnyTransition {
        guard animatesPayloadReplacement, !reduceMotion else {
            return .identity
        }
        return AnyTransition(.blurReplace)
    }
}

struct ReceiveQRCodeBrandMark: View {
    static let sizeRatio: CGFloat = 0.18

    var body: some View {
        GeometryReader { geometry in
            let sideLength = min(
                geometry.size.width,
                geometry.size.height
            ) * Self.sizeRatio

            ZStack {
                RoundedRectangle(cornerRadius: sideLength * 0.23, style: .continuous)
                    .fill(WalletTheme.qrCodeSurface)

                // Keep the official light app icon intact, with clear space
                // around it and the same bounded QR coverage in either theme.
                OnboardingBrandMark(size: sideLength * 0.84)
                    .environment(\.colorScheme, .light)
            }
            .frame(width: sideLength, height: sideLength)
            .position(
                x: geometry.size.width / 2,
                y: geometry.size.height / 2
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
