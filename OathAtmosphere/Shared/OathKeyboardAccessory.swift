import UIKit

/// UIKit sizes and moves this transparent accessory with the keyboard. The
/// page's existing background continues through the keyboard safe area; this
/// container adds no full-width fill or blur. Glass belongs only to the controls.
@MainActor final class OathKeyboardAccessory: UIView {
    let toolbar: OathKeyboardToolbar
    private let keyboardSpacing: CGFloat = 12

    init(identifierPrefix: String = "keyboard") {
        toolbar = OathKeyboardToolbar(identifierPrefix: identifierPrefix)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        frame.size.height = intrinsicContentSize.height
        addSubview(toolbar)
        // UIKit temporarily measures accessories at zero height. Keep the
        // toolbar at its natural height instead of constraining it to a
        // negative height (container minus the keyboard gap) during that pass.
        layoutToolbar()
        toolbar.onSizeChange = { [weak self] in
            self?.invalidateIntrinsicContentSize()
            self?.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateAppearance(_ style: UIUserInterfaceStyle) {
        // UIKit hosts accessories outside the screen's view hierarchy. Carry
        // the source screen's appearance to this view only, including while the
        // keyboard is already visible; never override a keyboard/app window.
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: toolbar.intrinsicContentSize.height + keyboardSpacing)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: intrinsicContentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutToolbar()
    }

    private func layoutToolbar() {
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width,
                               height: toolbar.intrinsicContentSize.height)
    }

    static func removeFromSearch(_ field: UISearchTextField) {
        // Search already has native cancellation and a Search return key.
        // Remove only our accessory; never replace system-owned input views.
        guard field.inputAccessoryView is OathKeyboardAccessory else { return }
        field.inputAccessoryView = nil
        if field.isFirstResponder { field.reloadInputViews() }
    }
}

/// A single glass surface fits its content, anchored at the keyboard's right
/// edge. Native diffable updates retain word identities and animate the list.
@MainActor final class OathKeyboardToolbar: UIView, UICollectionViewDelegateFlowLayout {
    var onSizeChange: (() -> Void)?
    private let glass = UIVisualEffectView()
    private let collection: SuggestionCollectionView
    private let done = UIButton(type: .system)
    private let doneSeparator = UIView()
    private let measurementButton = UIButton(type: .system)
    private var barWidth: NSLayoutConstraint!
    private var doneWidth: NSLayoutConstraint!
    private var separatorWidth: NSLayoutConstraint!
    private var words = [String]()
    private var displayedWords = [String]()
    private var wordSizes = [String: CGSize]()
    private var snapshotInFlight = false
    private var needsReconfigure = false
    private var lastLayoutWidth: CGFloat = 0
    private var onWord: ((String) -> Void)?
    private var onDone: (() -> Void)?

    private lazy var dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) {
        [weak self] collection, indexPath, word in
        guard let self,
              let cell = collection.dequeueReusableCell(withReuseIdentifier: "word", for: indexPath) as? WordCell
        else { return nil }
        cell.configure(word: word, index: indexPath.item,
                       configuration: self.buttonConfiguration(word: word), hairline: self.hairlineWidth)
        cell.onSelect = { [weak self] in
            // An outgoing cell can still be visible during a native removal.
            // Never commit a suggestion that no longer matches the live input.
            guard let self, self.words.contains(word) else { return }
            self.onWord?(word)
        }
        return cell
    }

    init(identifierPrefix: String) {
        let layout = SuggestionFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection = SuggestionCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "\(identifierPrefix).keyboardToolbar"
        // Match the mnemonic dictionary order, independently of app language.
        semanticContentAttribute = identifierPrefix == "recovery" ? .forceLeftToRight : .unspecified
        if #available(iOS 26.0, *) {
            glass.effect = UIGlassEffect(style: .regular)
            glass.cornerConfiguration = .capsule()
        } else {
            glass.effect = UIBlurEffect(style: .systemMaterial)
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
        }
        glass.accessibilityIdentifier = "\(identifierPrefix).suggestionSurface"
        addSubview(glass)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.showsVerticalScrollIndicator = false
        collection.alwaysBounceVertical = false
        collection.isDirectionalLockEnabled = true
        collection.contentInsetAdjustmentBehavior = .never
        collection.accessibilityIdentifier = "\(identifierPrefix).suggestions"
        collection.delegate = self
        collection.register(WordCell.self, forCellWithReuseIdentifier: "word")
        collection.alpha = 0
        collection.isUserInteractionEnabled = false
        collection.accessibilityElementsHidden = true
        glass.contentView.addSubview(collection)
        glass.contentView.addSubview(doneSeparator)
        glass.contentView.addSubview(done)
        doneSeparator.backgroundColor = .separator
        doneSeparator.alpha = 0
        done.configuration = buttonConfiguration()
        done.accessibilityIdentifier = "\(identifierPrefix).keyboardDone"
        done.addAction(UIAction { [weak self] _ in OathHaptics.shared.perform(.dismiss) { self?.onDone?() } }, for: .touchUpInside)
        for view in [glass, collection, doneSeparator, done] { view.translatesAutoresizingMaskIntoConstraints = false }
        barWidth = glass.widthAnchor.constraint(equalToConstant: done.intrinsicContentSize.width)
        doneWidth = done.widthAnchor.constraint(equalToConstant: done.intrinsicContentSize.width)
        separatorWidth = doneSeparator.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            barWidth,
            collection.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            collection.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            collection.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            collection.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            doneSeparator.leadingAnchor.constraint(equalTo: collection.trailingAnchor),
            doneSeparator.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            doneSeparator.heightAnchor.constraint(equalTo: glass.contentView.heightAnchor, multiplier: 0.45),
            separatorWidth,
            done.leadingAnchor.constraint(equalTo: doneSeparator.trailingAnchor),
            done.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            done.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            done.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
            doneWidth
        ])
        // Establish the empty section before any interactive snapshots arrive.
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) {
            (view: OathKeyboardToolbar, _: UITraitCollection) in
            view.done.configuration = view.buttonConfiguration()
            view.wordSizes.removeAll()
            view.measureWords()
            view.needsReconfigure = true
            view.updateSurface(animated: false)
            view.applyLatestSnapshot()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(words: [String], doneLabel: String, onWord: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        self.onWord = onWord
        self.onDone = onDone
        done.accessibilityLabel = doneLabel
        guard self.words != words else { return }
        layoutIfNeeded()
        self.words = words
        measureWords()
        updateSurface(animated: shouldAnimate)
        applyLatestSnapshot()
    }

    func clear() {
        onWord = nil
        onDone = nil
        words = []
        updateSurface(animated: false)
        applyLatestSnapshot()
    }

    private var shouldAnimate: Bool { window != nil && !UIAccessibility.isReduceMotionEnabled }
    private var hairlineWidth: CGFloat { OathHairlineMetrics.thickness(displayScale: traitCollection.displayScale) }
    private var preferredHeight: CGFloat {
        ceil(max(done.intrinsicContentSize.height, words.compactMap { wordSizes[$0]?.height }.max() ?? 0))
    }
    private var preferredWidth: CGFloat {
        guard !words.isEmpty else { return done.intrinsicContentSize.width }
        let contentWidth = words.reduce(CGFloat.zero) { $0 + (wordSizes[$1]?.width ?? 0) }
        // One divider between words, plus the last divider beside Done.
        return ceil(contentWidth + CGFloat(words.count) * hairlineWidth + done.intrinsicContentSize.width)
    }
    private var fittingWidth: CGFloat {
        let available = bounds.width > 0 ? max(done.intrinsicContentSize.width, bounds.width - 32) : preferredWidth
        return min(preferredWidth, available)
    }

    private func measureWords() {
        // Retain current/outgoing sizes while UIKit animates the diff. Only
        // dictionary suggestions are cached here, never the entered phrase.
        for word in words where wordSizes[word] == nil {
            measurementButton.configuration = buttonConfiguration(word: word)
            let size = measurementButton.intrinsicContentSize
            wordSizes[word] = CGSize(width: max(44, ceil(size.width)), height: ceil(size.height))
        }
    }

    private func updateSurface(animated: Bool) {
        layoutIfNeeded()
        barWidth.constant = fittingWidth
        doneWidth.constant = done.intrinsicContentSize.width
        separatorWidth.constant = words.isEmpty ? 0 : hairlineWidth
        collection.isUserInteractionEnabled = !words.isEmpty
        collection.accessibilityElementsHidden = words.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onSizeChange?()
        let changes = {
            self.collection.alpha = self.words.isEmpty ? 0 : 1
            self.doneSeparator.alpha = self.words.isEmpty ? 0 : 1
            (self.superview ?? self).layoutIfNeeded()
        }
        if animated {
            UIView.animate(springDuration: 0.3, bounce: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            UIView.performWithoutAnimation(changes)
        }
    }

    private func applyLatestSnapshot() {
        // Fast typing replaces the pending state, rather than queuing every
        // intermediate prefix or interrupting UIKit's in-flight cell updates.
        guard !snapshotInFlight, displayedWords != words || needsReconfigure else { return }
        let nextWords = words
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(nextWords)
        snapshot.reconfigureItems(nextWords.filter { previous.contains($0) })
        needsReconfigure = false
        snapshotInFlight = true
        displayedWords = nextWords
        collection.setContentOffset(.zero, animated: shouldAnimate)
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate) { [weak self] in
            guard let self else { return }
            self.snapshotInFlight = false
            self.applyLatestSnapshot()
        }
    }

    private func buttonConfiguration(word: String? = nil) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        if let word {
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
            configuration.title = word
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes
                result.font = font
                return result
            }
        } else {
            configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
            // UIButton's native configuration supplies the symbol metrics.
            // A fixed point size would bypass its font and trait handling.
        }
        return configuration
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        guard let word = dataSource.itemIdentifier(for: indexPath) else { return .zero }
        let size = wordSizes[word] ?? CGSize(width: 44, height: preferredHeight)
        // Exactly one horizontal row. UIKit supplies the accessory's measured
        // height, including while it is transitioning to a new text size.
        return CGSize(width: size.width + (indexPath.item == 0 ? 0 : hairlineWidth),
                      height: max(1, collectionView.bounds.height))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    override func layoutSubviews() {
        // Scene/keyboard width changes re-fit the surface without resetting
        // the list's scroll offset or manufacturing another list update.
        if bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            barWidth.constant = fittingWidth
        }
        super.layoutSubviews()
        if #unavailable(iOS 26.0) { glass.layer.cornerRadius = glass.bounds.height / 2 }
    }

    private final class WordCell: UICollectionViewCell {
        let button = UIButton(type: .system)
        private let separator = UIView()
        private var separatorWidth: NSLayoutConstraint!
        var onSelect: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            contentView.addSubview(separator)
            contentView.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.isUserInteractionEnabled = false
            separator.backgroundColor = .separator
            separatorWidth = separator.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                separator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                separator.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.45),
                separatorWidth,
                button.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
                button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                button.topAnchor.constraint(equalTo: contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            button.addAction(UIAction { [weak self] _ in OathHaptics.shared.perform(.selection) { self?.onSelect?() } }, for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func configure(word: String, index: Int, configuration: UIButton.Configuration, hairline: CGFloat) {
            button.configuration = configuration
            button.titleLabel?.numberOfLines = 1
            button.accessibilityIdentifier = "recovery.suggestion.\(index)"
            button.accessibilityLabel = word
            separatorWidth.constant = index == 0 ? 0 : hairline
            separator.isHidden = index == 0
        }

        override func prepareForReuse() {
            super.prepareForReuse()
            onSelect = nil
            button.configuration = nil
            button.accessibilityLabel = nil
        }
    }

    private final class SuggestionCollectionView: UICollectionView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            // Dragging a word scrolls the row without committing that word.
            view is UIButton || super.touchesShouldCancel(in: view)
        }
    }

    private final class SuggestionFlowLayout: UICollectionViewFlowLayout {
        override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
            let context = super.invalidationContext(forBoundsChange: newBounds)
            if newBounds.size != collectionView?.bounds.size,
               let flowContext = context as? UICollectionViewFlowLayoutInvalidationContext {
                // The accessory changes height as a large-text row collapses.
                // Re-measure outgoing cells too, instead of retaining their
                // previous, taller frames inside the smaller keyboard area.
                flowContext.invalidateFlowLayoutDelegateMetrics = true
            }
            return context
        }
    }
}
