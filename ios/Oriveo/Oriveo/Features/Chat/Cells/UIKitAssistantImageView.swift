import SwiftUI
import UIKit

final class UIKitAssistantImageView: UIView {
    private let attachment: Attachment
    private let partitionUID: String
    private weak var parentViewController: UIViewController?

    private let imageView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var heightConstraint: NSLayoutConstraint!
    private var currentRatio: CGFloat = 0

    var onLanded: (() -> Void)?

    init(
        attachment: Attachment,
        partitionUID: String,
        parentViewController: UIViewController?
    ) {
        self.attachment = attachment
        self.partitionUID = partitionUID
        self.parentViewController = parentViewController
        super.init(frame: .zero)
        setupViews()
        loadImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        backgroundColor = UIColor(OriveoTheme.Palette.surfaceChrome)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        heightConstraint = heightAnchor.constraint(equalToConstant: 240)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        let ratio = Self.preferredAspectRatio(for: attachment, partitionUID: partitionUID)
        setAspectRatio(ratio)

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        imageView.setContentHuggingPriority(.init(1), for: .horizontal)
        imageView.setContentHuggingPriority(.init(1), for: .vertical)
        imageView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        addSubview(imageView)

        placeholderIcon.image = UIImage(systemName: "photo")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 28))
        placeholderIcon.tintColor = UIColor(OriveoTheme.Palette.textTertiary)
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderIcon)

        loadingIndicator.color = UIColor(OriveoTheme.Palette.textTertiary)
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.topAnchor.constraint(equalTo: placeholderIcon.bottomAnchor, constant: 8),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    private func setAspectRatio(_ ratio: CGFloat) {
        currentRatio = ratio
        applyHeightForCurrentBounds()
    }

    private func applyHeightForCurrentBounds() {
        guard currentRatio > 0 else { return }
        let w = bounds.width > 0 ? bounds.width : 320
        heightConstraint.constant = (w / currentRatio).rounded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard currentRatio > 0, bounds.width > 0 else { return }
        let h = (bounds.width / currentRatio).rounded()
        guard abs(heightConstraint.constant - h) > 0.5 else { return }
        heightConstraint.constant = h
        onLanded?()
    }


    private func loadImage() {
        let boundUID = partitionUID
        if let lid = attachment.localImageID,
           let cached = ImageStore.cachedUIImage(for: lid, partitionUID: boundUID) {
            showImage(cached)
            return
        }

        loadingIndicator.startAnimating()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.loadImageAsync(partitionUID: boundUID)
            guard let image else {
                self.loadingIndicator.stopAnimating()
                return
            }
            guard !Task.isCancelled, AppSessionStore.activeUID == boundUID else { return }
            self.showImage(image)
        }
    }

    private func loadImageAsync(partitionUID boundUID: String) async -> UIImage? {
        if let lid = attachment.localImageID {
            if let loaded = await ImageStore.loadDisplayImage(
                for: lid,
                maxPixelSize: 960,
                partitionUID: boundUID
            ) {
                return loaded
            }
        }

        if let tb = attachment.thumbnailBase64,
           let decoded = ImageStore.thumbnailImage(
               forBase64Encoded: tb,
               cacheKey: Self.previewCacheKey(for: attachment),
               maxPixelSize: 960,
               partitionUID: boundUID
           ) {
            return decoded
        }

        return nil
    }

    private func showImage(_ image: UIImage) {
        loadingIndicator.stopAnimating()
        placeholderIcon.isHidden = true
        imageView.image = image
        imageView.isHidden = false

        let ratio = image.size.width / max(image.size.height, 1)
        let ratioChanged = abs(ratio - currentRatio) > 0.01
        setAspectRatio(ratio)
        if ratioChanged { onLanded?() }
    }

    // MARK: - Actions

    @objc private func imageTapped() {
        guard let parentVC = parentViewController ?? findViewController() else { return }
        let viewer = ImageViewerSheet(attachment: attachment, partitionUID: partitionUID)
        let hostingVC = UIHostingController(rootView: viewer)
        hostingVC.modalPresentationStyle = .fullScreen
        parentVC.present(hostingVC, animated: true)
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }


    nonisolated static func preferredAspectRatio(
        for attachment: Attachment,
        partitionUID: String
    ) -> CGFloat {
        if let lid = attachment.localImageID {
            if let ratio = ImageStore.imageAspectRatio(
                for: lid,
                thumbnail: true,
                partitionUID: partitionUID
            ) { return ratio }
            if let ratio = ImageStore.imageAspectRatio(for: lid, partitionUID: partitionUID) { return ratio }
        }
        if let tb = attachment.thumbnailBase64,
           let ratio = ImageStore.imageAspectRatio(
               forBase64Encoded: tb,
               cacheKey: previewCacheKey(for: attachment),
               partitionUID: partitionUID
           ) {
            return ratio
        }
        return 4.0 / 3.0
    }

    nonisolated static func previewCacheKey(for attachment: Attachment) -> String {
        attachment.localImageID ?? attachment.id.uuidString
    }
}
