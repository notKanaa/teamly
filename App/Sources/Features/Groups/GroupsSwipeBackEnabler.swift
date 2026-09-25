import SwiftUI
import UIKit

/// Keeps the edge swipe « back » of a screen that hides its navigation bar and draws its own back button (the group
/// hero): UIKit refuses the pop gesture while the bar is hidden. While the screen is on top of its stack, the
/// navigation controller's pop gesture gets a delegate that lets it begin whenever there is a screen to go back to;
/// the previous delegate is put back as soon as the screen starts to leave (a push, or the pop itself).
///
/// Put it behind the screen: `.background { GroupsSwipeBackEnabler() }`. It draws nothing and takes no touch.
struct GroupsSwipeBackEnabler: UIViewControllerRepresentable {
    init() {}

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var recognizer: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            previousDelegate = pop.delegate
            recognizer = pop
            pop.delegate = self
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreDelegate()
        }

        private func restoreDelegate() {
            if let recognizer, recognizer.delegate === self {
                recognizer.delegate = previousDelegate
            }
            recognizer = nil
            previousDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
