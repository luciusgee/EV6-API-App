import UIKit

/// A Done bar above every keyboard in the app, so a number pad (which has no return key) can always
/// be closed. Added to each text field and text view as it starts editing, sheets and alerts included.
@MainActor
enum KeyboardDoneBar {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { attach(to: note.object) }
            }
        }
    }

    private static func attach(to object: Any?) {
        if let field = object as? UITextField, field.inputAccessoryView == nil {
            field.inputAccessoryView = bar()
            field.reloadInputViews()
        } else if let view = object as? UITextView, view.inputAccessoryView == nil, view.isEditable {
            view.inputAccessoryView = bar()
            view.reloadInputViews()
        }
    }

    private static func bar() -> UIToolbar {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        bar.sizeToFit()
        return bar
    }
}
