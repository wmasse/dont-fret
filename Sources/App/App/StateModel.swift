import SwiftUI
import Observation

/// Owns an `@Observable` model for the lifetime of a view and builds it exactly once.
///
/// `@State var model = Model()` evaluates `Model()` every time the view's struct is
/// re-created (SwiftUI then throws the extra instance away), which is fine for cheap models.
/// Models whose `init` touches hardware or allocates heavy objects (capture sessions,
/// players, device discovery) use this instead, matching what `@StateObject` used to do:
///
///     @StateModel private var recorder = StudioRecorder()
///
/// `$recorder.someProperty` gives a binding, like `@Bindable`.
@propertyWrapper
struct StateModel<Model: AnyObject & Observable>: DynamicProperty {
    private final class Storage {
        var model: Model?
    }

    @State private var storage = Storage()
    private let make: () -> Model

    init(wrappedValue: @autoclosure @escaping () -> Model) {
        make = wrappedValue
    }

    var wrappedValue: Model {
        if let model = storage.model { return model }
        let model = make()
        storage.model = model
        return model
    }

    var projectedValue: Bindable<Model> { Bindable(wrappedValue) }
}
