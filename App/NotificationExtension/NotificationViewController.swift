import UIKit
import UserNotifications
import UserNotificationsUI
import SleepCore

/// Ce qu'affiche la notification « Démarrer la nuit ? » quand on appuie longuement dessus :
/// une barre de 0 à 2 h. Les boutons sous la notification suivent la barre :
/// « Oui, dans 45 min » (identifiant « oui_45 », lu par l'app) et « Non ».
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let startLabel = UILabel()
    private let slider = UISlider()
    private let hintLabel = UILabel()
    private let feedback = UISelectionFeedbackGenerator()
    private var minutes = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.text = "Démarrer la nuit ?"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        valueLabel.textAlignment = .center

        startLabel.font = .preferredFont(forTextStyle: .subheadline)
        startLabel.textColor = .secondaryLabel
        startLabel.textAlignment = .center

        slider.minimumValue = 0
        slider.maximumValue = Float(NightDelay.maxMinutes)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

        let low = UILabel()
        low.text = "0"
        let high = UILabel()
        high.text = "2 h"
        for label in [low, high] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
        }
        let scale = UIStackView(arrangedSubviews: [low, UIView(), high])
        scale.axis = .horizontal

        hintLabel.text = "Glisse pour choisir quand l'enregistrement commence, puis touche « Oui » ci-dessous."
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, startLabel, slider, scale, hintLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(2, after: valueLabel)
        stack.setCustomSpacing(2, after: slider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -14)
        ])
        setMinutes(0, moveSlider: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        let fitting = view.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel)
        let height = max(fitting.height, 180)
        if abs(preferredContentSize.height - height) > 1 {
            preferredContentSize = CGSize(width: width, height: height)
        }
    }

    func didReceive(_ notification: UNNotification) {
        let initial = notification.request.content.userInfo[BedtimeReminder.defaultDelayKey] as? Int ?? 0
        setMinutes(initial, moveSlider: true)
    }

    @objc private func sliderChanged() {
        let value = NightDelay.clamp(Double(slider.value))
        guard value != minutes else { return }
        feedback.selectionChanged()
        setMinutes(value, moveSlider: false)
    }

    private func setMinutes(_ value: Int, moveSlider: Bool) {
        minutes = NightDelay.clamp(Double(value))
        if moveSlider { slider.value = Float(minutes) }
        let text = NightDelay.text(minutes)
        valueLabel.text = text.prefix(1).uppercased() + text.dropFirst()
        if minutes > 0 {
            let start = Date().addingTimeInterval(Double(minutes) * 60)
            startLabel.text = "Début vers " + start.formatted(date: .omitted, time: .shortened)
        } else {
            startLabel.text = "Calibration de 30 s sur le dos au début"
        }
        let yes = UNNotificationAction(identifier: NightDelay.actionIdentifier(minutes),
                                       title: minutes == 0 ? "Oui, maintenant" : "Oui, \(text)",
                                       options: [.foreground])
        let no = UNNotificationAction(identifier: BedtimeReminder.declineAction, title: "Non", options: [.destructive])
        extensionContext?.notificationActions = [yes, no]
    }
}
