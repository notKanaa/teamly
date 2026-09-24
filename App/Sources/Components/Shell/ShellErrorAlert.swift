import Observation
import SwiftUI
import TeamTasksCore

/// The « Erreur » alert of a view model's `error` (every view model of TeamTasksCore is `ErrorPresenting`).
/// Dismissing it clears the error.
struct ShellErrorAlert<Model: ErrorPresenting & Observable>: ViewModifier {
    @Bindable var model: Model
    /// False while another presentation of the same model shows the error (e.g. a sheet with its own alert).
    var isEnabled = true

    func body(content: Content) -> some View {
        content.alert("Erreur", isPresented: isEnabled ? $model.isShowingError : .constant(false)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

extension View {
    /// Presents `model.error` in an « Erreur » alert.
    func shellErrorAlert<Model: ErrorPresenting & Observable>(_ model: Model, isEnabled: Bool = true) -> some View {
        modifier(ShellErrorAlert(model: model, isEnabled: isEnabled))
    }
}
