//
//  ScrollTabController.swift
//  tabTestStoryboards
//
//  Created by Noah Nübling on 16.06.22.
//

import Cocoa
import ReactiveSwift
import ReactiveCocoa

private final class FlippedTuningDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@available(macOS 11.0, *)
class ScrollTabController: NSViewController, NSTextFieldDelegate {
    
    /// Config
    
    var smooth = ConfigValue<String>(configPath: "Scroll.smooth")
    var trackpad = ConfigValue<Bool>(configPath: "Scroll.trackpadSimulation")
    var reverseDirection = ConfigValue<Bool>(configPath: "Scroll.reverseDirection")
    var invertZoom = ConfigValue<Bool>(configPath: "Scroll.invertZoom")
    var invertBallScroll = ConfigValue<Bool>(configPath: "Scroll.invertBallScroll")

    /// Fork: trackball tuning controls

    private struct TuningSpec {
        let configKey: String
        let stringKey: String
        let hintKey: String
        let fallback: Double
        let defaultMinimum: Double
        let defaultMaximum: Double
        let supportedMinimum: Double
        let supportedMaximum: Double

        var rangeConfigBase: String {
            "Scroll.tuningRanges." + String(configKey.split(separator: ".").last!)
        }
    }

    private final class TuningControl {
        let spec: TuningSpec
        let slider: NSSlider
        let valueField: NSTextField
        let minimumField: NSTextField
        let maximumField: NSTextField
        let detailLabel: NSTextField

        init(spec: TuningSpec,
             slider: NSSlider,
             valueField: NSTextField,
             minimumField: NSTextField,
             maximumField: NSTextField,
             detailLabel: NSTextField) {
            self.spec = spec
            self.slider = slider
            self.valueField = valueField
            self.minimumField = minimumField
            self.maximumField = maximumField
            self.detailLabel = detailLabel
        }
    }

    private var tuningControlsByKey: [String: TuningControl] = [:]
    private var tuningKeyBySlider: [NSSlider: String] = [:]
    private var tuningKeyByValueField: [NSTextField: String] = [:]
    private var tuningKeyByRangeField: [NSTextField: String] = [:]
    private var tuningKeyByRestoreButton: [NSButton: String] = [:]
    private var pendingTuningCommit: DispatchWorkItem?
    private weak var resetTuningRangesButton: NSButton?
    private var tuningWindowController: NSWindowController?
    var scrollSpeed = ConfigValue<String>(configPath: "Scroll.speed")
    var horizontalMod = ConfigValue<UInt>(configPath: "Scroll.modifiers.horizontal")
    var zoomMod = ConfigValue<UInt>(configPath: "Scroll.modifiers.zoom")
    var swiftMod = ConfigValue<UInt>(configPath: "Scroll.modifiers.swift")
    var preciseMod = ConfigValue<UInt>(configPath: "Scroll.modifiers.precise")
    
    /// Also see `ReactiveFlags` is this doesn't work
    
    /// Outlets
    
    @IBOutlet weak var masterStack: CollapsingStackView!
    

    
    
    
    
    @IBOutlet weak var smoothPicker: NSPopUpButton!
    
    @IBOutlet weak var trackpadSection: NSStackView!
    @IBOutlet weak var trackpadToggle: NSButton!
    @IBOutlet weak var trackpadHint: NSTextField!
    
    @IBOutlet weak var reverseDirectionToggle: NSButton!
    
    @IBOutlet weak var speedPicker: NSPopUpButton!
    
    @IBOutlet weak var horizontalModField: ModCaptureTextField!
    @IBOutlet weak var zoomModField: ModCaptureTextField!
    @IBOutlet weak var swiftModField: ModCaptureTextField!
    @IBOutlet weak var preciseModField: ModCaptureTextField!
    @IBOutlet weak var restoreDefaultModsButton: NSButton!
    
    /// Did appear
    
    override func viewDidAppear() {
        
        /// Remove focus
        ///     Sometimes, one of the modifierCapture fields is randomly selected. This hopefully prevents that.
        ///     Need to do asynAfter 0.0 seconds for it to work (I think - not well tested) that makes it do it on the next runLoop cycle I think.
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.0, execute: {
            MainAppState.shared.window?.makeFirstResponder(nil)
        })
        
        /// Turn off killswitch
        
        let isDisabled = config("General.scrollKillSwitch") as! Bool /// From the debugger it seems you can only cast NSNumber to bool with as! not with as?. That weird??
        if isDisabled {
            
            /// Turn off killSwitch
            setConfig("General.scrollKillSwitch", false as NSObject)
            commitConfig()
            
            /// Show message to user

            Toasts.showReviveToast(showButtons: false, showScroll: true)
        }
    }
    
    /// Fork: trackball tuning controls

    private lazy var tuningNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.allowsFloats = true
        formatter.usesGroupingSeparator = false
        return formatter
    }()

    private var tuningSpecs: [TuningSpec] {
        /// Fallbacks and supported ranges must match `default_config.plist > Scroll.tuning` and ScrollConfig.
        /// Range defaults only affect editing in this UI. The Helper continues to receive the exact stored value.
        [
            TuningSpec(configKey: "Scroll.tuning.sensitivity", stringKey: "scroll.tuning.sensitivity", hintKey: "scroll.tuning.sensitivity.hint", fallback: 0.10, defaultMinimum: 0.0, defaultMaximum: 1.0, supportedMinimum: 0.0, supportedMaximum: 10.0),
            TuningSpec(configKey: "Scroll.tuning.acceleration", stringKey: "scroll.tuning.acceleration", hintKey: "scroll.tuning.acceleration.hint", fallback: 1.0, defaultMinimum: 0.0, defaultMaximum: 1.0, supportedMinimum: 0.0, supportedMaximum: 5.0),
            TuningSpec(configKey: "Scroll.tuning.maxSpeed", stringKey: "scroll.tuning.maximum-speed", hintKey: "scroll.tuning.maximum-speed.hint", fallback: 0.5, defaultMinimum: 0.1, defaultMaximum: 1.0, supportedMinimum: 0.1, supportedMaximum: 10.0),
            TuningSpec(configKey: "Scroll.tuning.smoothness", stringKey: "scroll.tuning.smoothness", hintKey: "scroll.tuning.smoothness.hint", fallback: 0.5, defaultMinimum: 0.0, defaultMaximum: 1.0, supportedMinimum: 0.0, supportedMaximum: 10.0),
            TuningSpec(configKey: "Scroll.tuning.slowSmoothness", stringKey: "scroll.tuning.slow-smoothness", hintKey: "scroll.tuning.slow-smoothness.hint", fallback: 0.90, defaultMinimum: 0.0, defaultMaximum: 1.0, supportedMinimum: 0.0, supportedMaximum: 10.0),
            TuningSpec(configKey: "Scroll.tuning.adaptiveSmoothnessEndSpeedRatio", stringKey: "scroll.tuning.adaptive-until", hintKey: "scroll.tuning.adaptive-until.hint", fallback: 0.125, defaultMinimum: 0.025, defaultMaximum: 0.30, supportedMinimum: 0.001, supportedMaximum: 10.0),
            TuningSpec(configKey: "Scroll.tuning.glide", stringKey: "scroll.tuning.glide", hintKey: "scroll.tuning.glide.hint", fallback: 0.75, defaultMinimum: 0.0, defaultMaximum: 1.0, supportedMinimum: 0.0, supportedMaximum: 1.1),
        ]
    }

    private func tuningReadout(keyPath: String, value: Double) -> String {
        if keyPath == "Scroll.tuning.maxSpeed" {
            let sensitivity = (config("Scroll.tuning.sensitivity") as? NSNumber)?.doubleValue ?? 0.10
            let pxAtRefSpeed = 10.0 + sensitivity * 140.0
            let pixelsPerSecond = pxAtRefSpeed * 50.0 * (30.0 * max(0.1, value))
            return pixelsPerSecond >= 1000
                ? String(format: "%.1fk px/s", pixelsPerSecond / 1000.0)
                : String(format: "%.0f px/s", pixelsPerSecond)
        }
        if keyPath == "Scroll.tuning.smoothness" || keyPath == "Scroll.tuning.slowSmoothness" {
            /// This is a duration multiplier, not a percentage of an abstract quality. Showing the value used by
            /// the engine makes the trade-off explicit: larger means reports are blended over more time.
            return String(format: "%.2f×", 0.4 + value * 1.2)
        }
        if keyPath == "Scroll.tuning.adaptiveSmoothnessEndSpeedRatio" {
            return String(format: "%.1f%% max", value * 100.0)
        }
        return String(format: "%.0f%%", value * 100.0)
    }

    private func refreshTuningReadouts() {
        for control in tuningControlsByKey.values {
            control.detailLabel.stringValue = tuningReadout(keyPath: control.spec.configKey,
                                                             value: control.slider.doubleValue)
        }
    }

    private func parsedNumber(from field: NSTextField) -> Double? {
        tuningNumberFormatter.number(from: field.stringValue)?.doubleValue
    }

    private func setNumericField(_ field: NSTextField, to value: Double) {
        field.stringValue = tuningNumberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func clipped(_ value: Double, low: Double, high: Double) -> Double {
        min(high, max(low, value))
    }

    private func scheduleTuningCommit() {
        pendingTuningCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingTuningCommit = nil
            commitConfig()
        }
        pendingTuningCommit = work
        /// Keep dragging responsive without writing the plist and messaging the Helper for every mouse event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: work)
    }

    private func flushTuningCommit() {
        pendingTuningCommit?.cancel()
        pendingTuningCommit = nil
        commitConfig()
    }

    private func currentRange(for spec: TuningSpec, containing value: Double) -> (Double, Double) {
        let storedMinimum = (config(spec.rangeConfigBase + ".minimum") as? NSNumber)?.doubleValue
            ?? spec.defaultMinimum
        let storedMaximum = (config(spec.rangeConfigBase + ".maximum") as? NSNumber)?.doubleValue
            ?? spec.defaultMaximum
        var minimum = clipped(storedMinimum, low: spec.supportedMinimum, high: spec.supportedMaximum)
        var maximum = clipped(storedMaximum, low: spec.supportedMinimum, high: spec.supportedMaximum)
        if minimum >= maximum {
            minimum = spec.defaultMinimum
            maximum = spec.defaultMaximum
        }
        /// Old or imported values remain editable even when they sit outside a custom visual range.
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        return (minimum, maximum)
    }

    private func makeNumericField(value: Double, width: CGFloat, accessibilityLabel: String) -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.formatter = tuningNumberFormatter
        field.delegate = self
        field.controlSize = .small
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.setAccessibilityLabel(accessibilityLabel)
        setNumericField(field, to: value)
        return field
    }

    private func addTuningLauncher() {

        /// Hide upstream's Smoothness and Speed pickers.
        ///     Hidden, not deleted: their outlets stay wired and their reactive bindings keep running, so the
        ///     underlying `Scroll.smooth` / `Scroll.speed` config values keep their current meaning. `smooth` still
        ///     selects *which* animation curve is used (LowInertia etc.) — the Smoothness slider then overrides that
        ///     curve's step duration (see ScrollConfig.tuned()). masterStack sets detachesHiddenViews=YES in IB, so
        ///     hidden rows collapse properly here.
        for control in [smoothPicker as NSView?, speedPicker as NSView?] {
            guard let control = control else { continue }
            var row: NSView = control
            while let parent = row.superview, parent !== masterStack { row = parent }
            if row.superview === masterStack {
                row.isHidden = true
            } else {
                assert(false, "ScrollTab layout changed: picker is not inside masterStack.")
            }
        }

        let title = NSTextField(labelWithString: MFLocalizedString("scroll.tuning.section-title", comment: ""))
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let hint = NSTextField(wrappingLabelWithString: MFLocalizedString("scroll.tuning.launcher-hint", comment: ""))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.setContentHuggingPriority(.required, for: .vertical)
        hint.setContentCompressionResistancePriority(.required, for: .vertical)

        let openButton = NSButton(title: MFLocalizedString("scroll.tuning.open", comment: ""),
                                  target: self,
                                  action: #selector(showTuningWindow(_:)))
        openButton.bezelStyle = .rounded
        openButton.setAccessibilityIdentifier("axOpenScrollingFeel")
        openButton.setContentHuggingPriority(.required, for: .vertical)
        openButton.setContentCompressionResistancePriority(.required, for: .vertical)

        let section = NSStackView(views: [title, hint, openButton])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 7
        section.setHuggingPriority(.required, for: .vertical)
        section.setContentHuggingPriority(.required, for: .vertical)
        section.setContentCompressionResistancePriority(.required, for: .vertical)

        masterStack.insertArrangedSubview(section, at: 0)
    }

    @objc private func showTuningWindow(_ sender: Any?) {
        /// Opening another key window can interrupt the main tab controller's cross-fade. Finish the visible state
        /// synchronously so the inactive main window cannot be left with transparent tab content.
        view.alphaValue = 1.0
        view.subviews.first?.alphaValue = 1.0
        if let mainWindow = MainAppState.shared.window {
            mainWindow.alphaValue = 1.0
            mainWindow.isOpaque = true
            mainWindow.backgroundColor = .windowBackgroundColor
        }
        if tuningWindowController == nil {
            tuningWindowController = makeTuningWindowController()
        }
        tuningWindowController?.showWindow(self)
        tuningWindowController?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeTuningWindowController() -> NSWindowController {
        tuningControlsByKey.removeAll()
        tuningKeyBySlider.removeAll()
        tuningKeyByValueField.removeAll()
        tuningKeyByRangeField.removeAll()
        tuningKeyByRestoreButton.removeAll()

        let contentController = NSViewController()
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentController.view = root

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        let document = FlippedTuningDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        document.addSubview(stack)

        let windowTitle = NSTextField(labelWithString: MFLocalizedString("scroll.tuning.window-title", comment: ""))
        windowTitle.font = .systemFont(ofSize: 20, weight: .semibold)

        let windowHint = NSTextField(wrappingLabelWithString: MFLocalizedString("scroll.tuning.section-hint", comment: ""))
        windowHint.textColor = .secondaryLabelColor
        windowHint.maximumNumberOfLines = 2

        let resetRanges = NSButton(title: MFLocalizedString("scroll.tuning.reset-ranges", comment: ""),
                                   target: self,
                                   action: #selector(resetAllTuningRanges(_:)))
        resetRanges.bezelStyle = .rounded
        resetRanges.toolTip = MFLocalizedString("scroll.tuning.reset-ranges.hint", comment: "")
        resetTuningRangesButton = resetRanges

        let heading = NSStackView(views: [windowTitle, NSView(), resetRanges])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(windowHint)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        windowHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        for spec in tuningSpecs {
            let row = makeTuningRow(for: spec)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = MFLocalizedString("scroll.tuning.window-title", comment: "")
        window.contentViewController = contentController
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("ScrollingFeelWindow")
        window.center()
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        refreshResetRangesButton()
        return NSWindowController(window: window)
    }

    private func makeTuningRow(for spec: TuningSpec) -> NSView {
        let name = MFLocalizedString(spec.stringKey, comment: "")
        let description = MFLocalizedString(spec.hintKey, comment: "")
        let storedValue = (config(spec.configKey) as? NSNumber)?.doubleValue ?? spec.fallback
        let value = clipped(storedValue, low: spec.supportedMinimum, high: spec.supportedMaximum)
        let range = currentRange(for: spec, containing: value)

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let detail = NSTextField(labelWithString: tuningReadout(keyPath: spec.configKey, value: value))
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor

        let titleRow = NSStackView(views: [title, NSView(), detail])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY

        let supportedMinimum = tuningNumberFormatter.string(from: NSNumber(value: spec.supportedMinimum))
            ?? String(spec.supportedMinimum)
        let supportedMaximum = tuningNumberFormatter.string(from: NSNumber(value: spec.supportedMaximum))
            ?? String(spec.supportedMaximum)
        let supportedRange = String(format: MFLocalizedString("scroll.tuning.supported-range", comment: ""),
                                    supportedMinimum,
                                    supportedMaximum)
        let descriptionLabel = NSTextField(wrappingLabelWithString: description + "\n" + supportedRange)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.maximumNumberOfLines = 3
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let slider = NSSlider(value: value, minValue: range.0, maxValue: range.1,
                              target: self, action: #selector(tuningSliderChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityIdentifier("axTuning_" + spec.configKey)
        slider.setAccessibilityLabel(name)
        slider.toolTip = description
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true

        let minimumField = makeNumericField(value: range.0, width: 92,
                                            accessibilityLabel: MFLocalizedString("scroll.tuning.minimum", comment: "") + " " + name)
        let maximumField = makeNumericField(value: range.1, width: 92,
                                            accessibilityLabel: MFLocalizedString("scroll.tuning.maximum", comment: "") + " " + name)
        for field in [minimumField, maximumField] {
            field.target = self
            field.action = #selector(tuningRangeFieldChanged(_:))
        }

        let valueField = makeNumericField(value: value, width: 92, accessibilityLabel: name)
        valueField.target = self
        valueField.action = #selector(tuningValueFieldChanged(_:))
        valueField.toolTip = MFLocalizedString("scroll.tuning.exact-value.hint", comment: "")

        let restore = NSButton(title: MFLocalizedString("scroll.tuning.restore-range", comment: ""),
                               target: self,
                               action: #selector(restoreTuningRange(_:)))
        restore.bezelStyle = .inline
        restore.controlSize = .small

        let minimumLabel = NSTextField(labelWithString: MFLocalizedString("scroll.tuning.minimum", comment: ""))
        let maximumLabel = NSTextField(labelWithString: MFLocalizedString("scroll.tuning.maximum", comment: ""))
        let valueLabel = NSTextField(labelWithString: MFLocalizedString("scroll.tuning.value", comment: ""))
        for label in [minimumLabel, maximumLabel, valueLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let fields = NSStackView(views: [minimumLabel, minimumField, maximumLabel, maximumField,
                                         valueLabel, valueField, NSView(), restore])
        fields.orientation = .horizontal
        fields.alignment = .centerY
        fields.spacing = 7

        let row = NSStackView(views: [titleRow, descriptionLabel, slider, fields])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        for arrangedView in [titleRow, descriptionLabel, slider, fields] {
            arrangedView.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -28).isActive = true
        }

        let control = TuningControl(spec: spec,
                                    slider: slider,
                                    valueField: valueField,
                                    minimumField: minimumField,
                                    maximumField: maximumField,
                                    detailLabel: detail)
        tuningControlsByKey[spec.configKey] = control
        tuningKeyBySlider[slider] = spec.configKey
        tuningKeyByValueField[valueField] = spec.configKey
        tuningKeyByRangeField[minimumField] = spec.configKey
        tuningKeyByRangeField[maximumField] = spec.configKey
        tuningKeyByRestoreButton[restore] = spec.configKey
        return row
    }

    @objc private func tuningSliderChanged(_ sender: NSSlider) {
        guard let key = tuningKeyBySlider[sender], let control = tuningControlsByKey[key] else {
            assertionFailure()
            return
        }
        setConfig(key, NSNumber(value: sender.doubleValue))
        setNumericField(control.valueField, to: sender.doubleValue)
        refreshTuningReadouts() /// Sensitivity also changes the px/s value shown for Maximum Speed.
        scheduleTuningCommit()
    }

    @objc private func tuningValueFieldChanged(_ sender: NSTextField) {
        commitTuningValueField(sender)
    }

    private func commitTuningValueField(_ field: NSTextField) {
        guard let key = tuningKeyByValueField[field], let control = tuningControlsByKey[key] else { return }
        guard let parsed = parsedNumber(from: field) else {
            NSSound.beep()
            setNumericField(field, to: control.slider.doubleValue)
            return
        }
        let value = clipped(parsed, low: control.slider.minValue, high: control.slider.maxValue)
        control.slider.doubleValue = value
        setNumericField(field, to: value)
        setConfig(key, NSNumber(value: value))
        refreshTuningReadouts()
        flushTuningCommit()
    }

    @objc private func tuningRangeFieldChanged(_ sender: NSTextField) {
        guard let key = tuningKeyByRangeField[sender], let control = tuningControlsByKey[key] else { return }
        commitTuningRangeFields(for: control)
    }

    private func commitTuningRangeFields(for control: TuningControl) {
        guard let parsedMinimum = parsedNumber(from: control.minimumField),
              let parsedMaximum = parsedNumber(from: control.maximumField) else {
            NSSound.beep()
            setNumericField(control.minimumField, to: control.slider.minValue)
            setNumericField(control.maximumField, to: control.slider.maxValue)
            return
        }

        let minimum = clipped(parsedMinimum,
                              low: control.spec.supportedMinimum,
                              high: control.spec.supportedMaximum)
        let maximum = clipped(parsedMaximum,
                              low: control.spec.supportedMinimum,
                              high: control.spec.supportedMaximum)
        guard minimum < maximum else {
            NSSound.beep()
            setNumericField(control.minimumField, to: control.slider.minValue)
            setNumericField(control.maximumField, to: control.slider.maxValue)
            return
        }

        control.slider.minValue = minimum
        control.slider.maxValue = maximum
        let value = clipped(control.slider.doubleValue, low: minimum, high: maximum)
        control.slider.doubleValue = value
        setNumericField(control.valueField, to: value)
        setNumericField(control.minimumField, to: minimum)
        setNumericField(control.maximumField, to: maximum)
        setConfig(control.spec.configKey, NSNumber(value: value))
        setConfig(control.spec.rangeConfigBase + ".minimum", NSNumber(value: minimum))
        setConfig(control.spec.rangeConfigBase + ".maximum", NSNumber(value: maximum))
        refreshTuningReadouts()
        refreshResetRangesButton()
        flushTuningCommit()
    }

    @objc private func restoreTuningRange(_ sender: NSButton) {
        guard let key = tuningKeyByRestoreButton[sender], let control = tuningControlsByKey[key] else { return }
        applyDefaultRange(to: control)
        commitConfig()
    }

    @objc private func resetAllTuningRanges(_ sender: NSButton) {
        pendingTuningCommit?.cancel()
        pendingTuningCommit = nil
        for control in tuningControlsByKey.values {
            applyDefaultRange(to: control)
        }
        commitConfig()
    }

    private func applyDefaultRange(to control: TuningControl) {
        control.slider.minValue = control.spec.defaultMinimum
        control.slider.maxValue = control.spec.defaultMaximum
        let value = clipped(control.slider.doubleValue,
                            low: control.spec.defaultMinimum,
                            high: control.spec.defaultMaximum)
        control.slider.doubleValue = value
        setNumericField(control.valueField, to: value)
        setNumericField(control.minimumField, to: control.spec.defaultMinimum)
        setNumericField(control.maximumField, to: control.spec.defaultMaximum)
        setConfig(control.spec.configKey, NSNumber(value: value))
        setConfig(control.spec.rangeConfigBase + ".minimum", NSNumber(value: control.spec.defaultMinimum))
        setConfig(control.spec.rangeConfigBase + ".maximum", NSNumber(value: control.spec.defaultMaximum))
        refreshTuningReadouts()
        refreshResetRangesButton()
    }

    private func refreshResetRangesButton() {
        resetTuningRangesButton?.isEnabled = tuningControlsByKey.values.contains {
            abs($0.slider.minValue - $0.spec.defaultMinimum) > 0.000_001
                || abs($0.slider.maxValue - $0.spec.defaultMaximum) > 0.000_001
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if tuningKeyByValueField[field] != nil {
            commitTuningValueField(field)
        } else if let key = tuningKeyByRangeField[field], let control = tuningControlsByKey[key] {
            commitTuningRangeFields(for: control)
        }
    }

    override func viewWillDisappear() {
        if pendingTuningCommit != nil {
            flushTuningCommit()
        }
        super.viewWillDisappear()
    }

    /// Init

    override func viewDidLoad() {
        super.viewDidLoad()
        
        /// There was some reason we don't use viewDidLoad here, and instead we use awakeFromNib. I think it had to do with preventing animations from playing when the app starts right into this tab or sth. But maybe it's just unnecessary.
        
        /// Smooth
        
        smooth.bindingTarget <~ smoothPicker.reactive.selectedIdentifiers.map({ $0!.rawValue })
        smoothPicker.reactive.selectedIdentifier <~ smooth.producer.map({ NSUserInterfaceItemIdentifier($0) })
         
        trackpadSection.reactive.isCollapsed <~ smooth.producer.map({ $0 != "high" })
        
        let MF_TEST = 0
        if MF_TEST == 0 { /// Remove the experimental "low" option in release builds
            smoothPicker.menu?.item(withIdentifier: NSUserInterfaceItemIdentifier("low"))?.isHidden = true
        }
        
        /// Trackpad
        trackpad.bindingTarget <~ trackpadToggle.reactive.boolValues
        trackpadToggle.reactive.boolValue <~ trackpad.producer
        
        /// Natural direction
        reverseDirection.bindingTarget <~ reverseDirectionToggle.reactive.boolValues
        reverseDirectionToggle.reactive.boolValue <~ reverseDirection.producer

        /// Fork: tuning window launcher (replaces the Smoothness / Speed pickers)
        addTuningLauncher()

        /// Fork: Invert zoom
        ///     Added in code rather than IB, like the other fork additions. `reverseDirectionToggle` is itself a
        ///     direct arranged subview of masterStack (a plain checkbox), so we mirror it and slot in right below.
        do {
            let toggle = NSButton(checkboxWithTitle: MFLocalizedString("scroll.invert-zoom", comment: ""),
                                  target: nil, action: nil)
            toggle.toolTip = MFLocalizedString("scroll.invert-zoom.hint", comment: "")
            toggle.setAccessibilityIdentifier("axInvertZoomToggle")

            /// Mirror the Reverse Direction toggle's vertical hugging (750 in IB).
            ///     masterStack is `distribution = fill`, so a subview with the default (250) hugging gets stretched
            ///     — and since TabViewController measures tabs by growing the window to 99999x99999
            ///     (TabViewController.swift:551), that would blow the tab's measured height up to 99999.
            toggle.setContentHuggingPriority(.init(750), for: .vertical)

            /// Insert directly below Reverse Direction.
            ///     Index is read back via masterStack.arrangedSubviews, which CollapsingStackView overrides to
            ///     unwrap its NoClipWrappers (Collapse.swift:140). That's safe here: wrappers replace their view
            ///     in place, so the unwrapped list stays the same length and order as the real one.
            if let i = masterStack.arrangedSubviews.firstIndex(of: reverseDirectionToggle) {
                masterStack.insertArrangedSubview(toggle, at: i + 1)
            } else {
                assert(false, "ScrollTab layout changed: reverseDirectionToggle is not in masterStack.")
                masterStack.addArrangedSubview(toggle)
            }

            invertZoom.bindingTarget <~ toggle.reactive.boolValues
            toggle.reactive.boolValue <~ invertZoom.producer
        }

        /// Fork: Invert ball scrolling (Scroll & Zoom Mode)
        ///     Sits with the other direction toggles even though it's driven by a Buttons-tab action — this is where
        ///     you look when something scrolls the wrong way.
        do {
            let toggle = NSButton(checkboxWithTitle: MFLocalizedString("scroll.invert-ball-scroll", comment: ""),
                                  target: nil, action: nil)
            toggle.toolTip = MFLocalizedString("scroll.invert-ball-scroll.hint", comment: "")
            toggle.setAccessibilityIdentifier("axInvertBallScrollToggle")
            toggle.setContentHuggingPriority(.init(750), for: .vertical) /// See the note above re: the 99999 probe

            /// Below the Invert Zoom toggle we just inserted (which is itself below Reverse Direction).
            if let i = masterStack.arrangedSubviews.firstIndex(where: { $0.accessibilityIdentifier() == "axInvertZoomToggle" }) {
                masterStack.insertArrangedSubview(toggle, at: i + 1)
            } else {
                assert(false, "ScrollTab layout changed: invert zoom toggle not found.")
                masterStack.addArrangedSubview(toggle)
            }

            invertBallScroll.bindingTarget <~ toggle.reactive.boolValues
            toggle.reactive.boolValue <~ invertBallScroll.producer
        }


        /// Scroll speed
        scrollSpeed.bindingTarget <~ speedPicker.reactive.selectedIdentifiers.map({ identifier in
            identifier!.rawValue
        })
        speedPicker.reactive.selectedIdentifier <~ scrollSpeed.producer.map({ NSUserInterfaceItemIdentifier($0) })
        
        /// Hardcode tab width
        applyHardcodedTabWidth("scrolling", self, widthControllingTextFields: [])
        
        /// Scrollwheel capture notifications
        /// Notes:
        /// - You can find discussion of the design-thoughts behind this inside `getCapturedButtonsAndExcludeButtonsThatAreOnlyCapturedByModifier:`
        /// - How to ship this:
        ///     - We're introducing new localizable strings, so we should ship this in a major update with a Beta version
        ///     - Once we shipped it, we should probably update the Captured Buttons Guide: https://redirect.macmousefix.com/?target=mmf-captured-buttons-guide - or create a new guide.
        
        let modProducer = SignalProducer.combineLatest(horizontalMod.producer, zoomMod.producer, swiftMod.producer, preciseMod.producer) /// We could reuse this down in the Keyboard modifier section, but currently, we're not
        let captureProducer = SignalProducer.combineLatest(smooth.producer, reverseDirection.producer, scrollSpeed.producer, modProducer).combinePrevious()
            
        captureProducer.startWithValues { (previous, current) in
            
            DDLogDebug("ScrollTab - Capture-relevant settings changed")
            
            if let toastedWindow = NSApp.mainWindow {
                
                let (smooth0, reverse0, speed0, mods0) = previous
                let (smooth1, reverse1, speed1, mods1) = current
                
                let (horizontal0, zoom0, swift0, precise0) = mods0
                let (horizontal1, zoom1, swift1, precise1) = mods1
                
                let wasCaptured = smooth0 != "off" || reverse0 || speed0 != "system" || horizontal0 != 0 || zoom0 != 0 || swift0 != 0 || precise0 != 0 /// Including the modifiers here is a little 'semantically incorrect' but we still do it. See `getCapturedButtonsAndExcludeButtonsThatAreOnlyCapturedByModifier:` [Sep 2025]
                let isCaptured  = smooth1 != "off" || reverse1 || speed1 != "system" || horizontal1 != 0 || zoom1 != 0 || swift1 != 0 || precise1 != 0
                    
                DDLogDebug("ScrollTab - smooth: \(smooth0)->\(smooth1) reverse: \(reverse0)->\(reverse1) speed: \(speed0)->\(speed1) horizontal: \(horizontal0)->\(horizontal1) zoom: \(zoom0)->\(zoom1) swift: \(swift0)->\(swift1) precise: \(precise0)->\(precise1)")
                
                if wasCaptured && !isCaptured {
                    CaptureToasts.showScrollWheelCaptureToast(false)
                }
                if !wasCaptured && isCaptured {
                    CaptureToasts.showScrollWheelCaptureToast(true)
                }
            }
        }
        
        /// Keyboard modifiers
        
        horizontalModField <~ horizontalMod.producer.map({ NSEvent.ModifierFlags(rawValue: $0) })
        horizontalMod <~ horizontalModField.signal.map({ $0.rawValue })
        zoomModField <~ zoomMod.producer.map({ NSEvent.ModifierFlags(rawValue: $0) })
        zoomMod <~ zoomModField.signal.map({ $0.rawValue })
        swiftModField <~ swiftMod.producer.map({ NSEvent.ModifierFlags(rawValue: $0) })
        swiftMod <~ swiftModField.signal.map({ $0.rawValue })
        preciseModField <~ preciseMod.producer.map({ NSEvent.ModifierFlags(rawValue: $0) })
        preciseMod <~ preciseModField.signal.map({ $0.rawValue })
        
        /// Keep these in sync with the `default_config`
        typealias Mods = NSEvent.ModifierFlags
        let defaultH: Mods = [.shift]
        let defaultZ: Mods = [.command]
        let defaultS: Mods = [.control]
        let defaultP: Mods = [.option]
        
        restoreDefaultModsButton.reactive.states.observeValues { state in
            self.horizontalMod.set(defaultH.rawValue)
            self.zoomMod.set(defaultZ.rawValue)
            self.swiftMod.set(defaultS.rawValue)
            self.preciseMod.set(defaultP.rawValue)
        }
        
        /// v Using Signal.combineLatest here might be easier.
        ///     Edit: I could do it using combinePrevious() on the modProducer we defined above, but I think it would be much more complicated and less elegant
        
        let allFlags = SignalProducer<(String, UInt), Never>.merge(horizontalMod.producer.map{ ("h", $0) }, zoomMod.producer.map{ ("z", $0) }, swiftMod.producer.map{ ("s", $0) }, preciseMod.producer.map{ ("p", $0) })
        allFlags.startWithValues { (src, flags) in
            
//            DispatchQueue.main.async { /// Need to dispatch async to prevent weird crashes inside ReactiveSwift. Edit: When / why did we comment this out? Seems to not be needed anymore
                
                /// Delete the modifiers which the user just set - delete them for all the other scroll modifications
                ///     So you can't set two different modifications to the same modifier
            
                if self.horizontalMod.get() == flags && src != "h" {
                    self.horizontalMod.set(0)
                }
                if self.zoomMod.get() == flags && src != "z" {
                    self.zoomMod.set(0)
                }
                if self.swiftMod.get() == flags && src != "s" {
                    self.swiftMod.set(0)
                }
                if self.preciseMod.get() == flags && src != "p" {
                    self.preciseMod.set(0)
                }
                
                /// Make restoreDefaults button appear/disappear
            
                var restoreDefaultsIsEnabled = true
                
                if self.horizontalMod.get() == defaultH.rawValue
                    && self.zoomMod.get() == defaultZ.rawValue
                    && self.swiftMod.get() == defaultS.rawValue
                    && self.preciseMod.get() == defaultP.rawValue {
                    
                    restoreDefaultsIsEnabled = false
                }
                
                Animate.with(CABasicAnimation(name: .default, duration: 0.1)) {
                    self.restoreDefaultModsButton.reactiveAnimator().alphaValue.set(restoreDefaultsIsEnabled ? 1.0 : 0.0)
                }
//            }
        }
    }
}
