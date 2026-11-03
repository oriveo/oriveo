import Foundation

/// Round operation of a studio work (studio_data_model.v1 `enums.operation`).
nonisolated enum StudioWorkOperationKind: String, CaseIterable, Hashable, Sendable {
    case generate
    case edit
    case `import`
}

/// Role of a reference image in a round (studio_data_model.v1 `enums.referenceRole`).
nonisolated enum StudioReferenceRole: String, CaseIterable, Hashable, Sendable {
    case base
    case subject
    case style
    case composition
    case person
    case element
}

/// Which picture an edit round starts from.
nonisolated enum StudioOperationBase: String, Hashable, Sendable {
    /// The current version of the open work.
    case currentVersion = "current_version"
    /// The first subject reference, imported as v1 before the edit.
    case firstSubjectAsV1 = "first_subject_as_v1"
}

/// Why no round can be started with the chosen model.
nonisolated enum StudioOperationBlock: String, Hashable, Sendable {
    case modelCannotReferenceImages = "model_cannot_reference_images"
    case modelNeedsImage = "model_needs_image"
}

/// The operation a send turns into (studio_data_model.v1 `operationTable`).
nonisolated struct StudioWorkOperation: Equatable, Sendable {
    var operation: StudioWorkOperationKind?
    var base: StudioOperationBase?
    var importFirst: Bool
    var blocked: StudioOperationBlock?

    /// - Parameters:
    ///   - inWorkDetail: the send happens inside an existing work (its current version is the base).
    ///   - imageRoles: roles of the attached reference images, in order.
    ///   - modelOperations: operations the chosen model offers.
    static func resolve(
        inWorkDetail: Bool,
        imageRoles: [StudioReferenceRole],
        modelOperations: Set<StudioWorkOperationKind>
    ) -> StudioWorkOperation {
        StudioWorkOperation(operation: nil, base: nil, importFirst: false, blocked: nil)
    }
}
