//  RequestPreferenceContractTests.swift
//  OriveoTests

import Foundation
import Testing
@testable import Oriveo

@Suite("Request preference and shape contract")
struct RequestPreferenceContractTests {


    @Test("Vocabulary Matches Contract")
    func vocabularyMatchesContract() throws {
        let contract = try Self.preferenceContract()
        let shape = try Self.shapeContract()

        #expect(contract.contractId == "request_preference_contract.v2")
        #expect(contract.version == 2)
        #expect(shape.contractId == "request_shape_contract.v2")
        #expect(shape.version == 2)

        #expect(contract.owners.map(\.id) == RequestPreferenceOwner.allCases.map(\.rawValue))
        #expect(shape.wireNaming.capabilityControlKeys == RequestPreferenceOwner.allCases.map(\.rawValue))

        #expect(contract.resolution.scopePriority
            == RequestPreferenceResolver.scopePriority.map(\.rawValue))
        #expect(contract.resolution.scopePriority.count == 7)
        #expect(contract.resolution.missingMeans == "inherit")
        #expect(contract.resolution.terminalStates == ["value", "omit"])
        #expect(contract.resolution.numericZeroIsExplicitValue)
        #expect(contract.resolution.lastWriteWins == false)

        #expect(contract.vocabulary.overrideStates == ["inherit", "value", "omit"])
        #expect(contract.vocabulary.valueModes == RequestPreferenceValueMode.allCases.map(\.rawValue))
        #expect(contract.vocabulary.controlAvailability
            == RequestControlAvailability.allCases.map(\.rawValue))
        #expect(contract.vocabulary.connectionAccess
            == RequestConnectionAccess.allCases.map(\.rawValue))
        #expect(contract.vocabulary.continuationKinds
            == RequestContinuationKind.allCases.map(\.rawValue))
        #expect(contract.vocabulary.resultStates == RequestResultState.allCases.map(\.rawValue))
        #expect(contract.vocabulary.observationEvidenceKinds
            == RequestObservationEvidence.allCases.map(\.rawValue))
        #expect(contract.vocabulary.continuationKinds.contains("fiber") == false)

        #expect(shape.controlStates == RequestControlAvailability.allCases.map(\.rawValue))
        #expect(shape.reasoningIntents.values == RequestReasoningIntent.allCases.map(\.rawValue))
        #expect(shape.reasoningIntents.availableIntentsOnlyOnCapability
            == RequestPreferenceOwner.reasoning.rawValue)
        #expect(shape.webIntents.values == ["force"])
        #expect(shape.webIntents.availableIntentsOnlyOnCapability
            == RequestPreferenceOwner.web.rawValue)
        #expect(shape.failSafe.actions == RequestRuntimeAction.allCases.map(\.rawValue))
        #expect(shape.failSafe.unknownControlState == RequestControlAvailability.unknown.rawValue)
        #expect(shape.failSafe.danglingRecipeRefDegradesTo == RequestControlAvailability.unknown.rawValue)

        #expect(shape.providerKindUniverse.count == 16)
        #expect(shape.providerKindUniverse.kinds == RequestProviderKind.allCases.map(\.rawValue))
    }

    @Test("Constants Match Contract")
    func constantsMatchContract() throws {
        let contract = try Self.preferenceContract()
        let shape = try Self.shapeContract()
        let overlay = contract.safeOverlay

        #expect(overlay.segmentPattern == RequestPreferenceResolver.overlaySegmentPattern)
        #expect(overlay.blockedSegmentsRecursive == RequestPreferenceResolver.blockedSegmentsRecursive)
        #expect(overlay.forbiddenChannels == RequestPreferenceResolver.forbiddenChannels)
        #expect(overlay.builderOwnedRootFields == RequestPreferenceResolver.builderOwnedRootFields)
        #expect(overlay.typedContributionOnlyRoots
            == RequestPreferenceResolver.typedContributionOnlyRoots)
        #expect(overlay.limits.maxBytes == RequestPreferenceResolver.overlayLimits.maxBytes)
        #expect(overlay.limits.maxDepth == RequestPreferenceResolver.overlayLimits.maxDepth)
        #expect(overlay.limits.maxNodes == RequestPreferenceResolver.overlayLimits.maxNodes)
        #expect(overlay.limits.maxOperations == RequestPreferenceResolver.overlayLimits.maxOperations)
        #expect(overlay.inputType == "json_object_fragment")
        #expect(overlay.pointerSyntax == "rfc6901")

        #expect(contract.typedContributions.targets == RequestContributionTarget.allCases.map(\.rawValue))
        #expect(contract.typedContributions.operations
            == [RequestPreferenceResolver.contributionAppendOperation])
        for (target, owners) in contract.typedContributions.allowedOwnerByTarget {
            let parsed = try #require(RequestContributionTarget(rawValue: target))
            #expect(RequestPreferenceResolver.allowedOwnerByTarget[parsed]?.map(\.rawValue) == owners)
        }

        for (kind, spec) in contract.continuation.kinds {
            let parsed = try #require(RequestContinuationKind(rawValue: kind))
            let local = try #require(RequestPreferenceResolver.continuationSpecs[parsed])
            #expect(local.maxSteps == spec.maxSteps, "\(kind) maxSteps")
            #expect(local.requiredStateFields == spec.requiredStateFields, "\(kind) requiredStateFields")
            #expect(local.opaqueReplay == spec.opaqueReplay, "\(kind) opaqueReplay")
            #expect(local.variants == (spec.variants ?? []), "\(kind) variants")
        }
        #expect(RequestPreferenceResolver.continuationSpecs.count == contract.continuation.kinds.count)

        let retry = contract.retryPolicy
        #expect(retry.automaticRetry == RequestPreferenceResolver.retryPolicy.automaticRetry)
        #expect(retry.allowedStatus == RequestPreferenceResolver.retryPolicy.allowedStatus)
        #expect(retry.allowedErrorClass == RequestPreferenceResolver.retryPolicy.allowedErrorClass)
        #expect(retry.requiresLocatedOwner == RequestPreferenceResolver.retryPolicy.requiresLocatedOwner)
        #expect(retry.requiresLocatedPointers == RequestPreferenceResolver.retryPolicy.requiresLocatedPointers)
        #expect(retry.explicitResendAction == RequestPreferenceResolver.retryPolicy.explicitResendAction)
        #expect(retry.savedPreferenceAfterRejection == RequestPreferenceResolver.retryPolicy.savedPreferenceAfterRejection)
        #expect(retry.neverAutomatic == RequestPreferenceResolver.retryPolicy.neverAutomatic)

        let wire = shape.wireNaming
        #expect(wire.runtimeEnvelopeKey == RequestPreferenceResolver.runtimeEnvelopeKey)
        #expect(wire.runtimeSchemaVersion == RequestPreferenceResolver.runtimeSchemaVersion)
        #expect(wire.runtimeEnvelopeFields == RequestPreferenceResolver.runtimeEnvelopeFields)
        #expect(wire.perModelControlsKey == RequestPreferenceResolver.capabilityControlsKey)
        #expect(wire.recipeReferenceKey == RequestPreferenceResolver.recipeReferenceKey)

        let rules = shape.stateRequirements
        #expect(rules.nonAutoMinSourceRefs == RequestPreferenceResolver.nonAutoMinSourceRefs)
        #expect(rules.fixedVerdicts.count == RequestPreferenceResolver.fixedVerdicts.count)
        for verdict in rules.fixedVerdicts {
            let local = try #require(RequestPreferenceResolver.fixedVerdicts.first {
                $0.providerKind.rawValue == verdict.providerKind
            })
            #expect(local.state.rawValue == verdict.state, "\(verdict.providerKind) state")
            #expect(local.reasonCode == verdict.reasonCode, "\(verdict.providerKind) reasonCode")
            #expect(local.autoRecipeAllowed == verdict.autoRecipeAllowed, "\(verdict.providerKind)")
        }
        #expect(rules.sourceRefExemptions.count == RequestPreferenceResolver.sourceRefExemptions.count)
        for exemption in rules.sourceRefExemptions {
            let local = try #require(RequestPreferenceResolver.sourceRefExemptions.first {
                $0.providerKind.rawValue == exemption.providerKind
            })
            #expect(local.state.rawValue == exemption.state, "\(exemption.providerKind) state")
            #expect(local.reasonCode == exemption.reasonCode, "\(exemption.providerKind) reasonCode")
        }
    }

    // MARK: - request_preference_contract.v2

    @Test("Resolution Cases")
    func resolutionCases() throws {
        let cases = try Self.preferenceContract().fixtures.resolutionCases
        #expect(cases.count == 5)

        for item in cases {
            _ = try #require(RequestPreferenceOwner(rawValue: item.owner), "\(item.caseId) owner")
            var layers: [RequestPreferenceLayer] = []
            for layer in item.layers {
                let scope = try #require(
                    RequestPreferenceScope(rawValue: layer.scope), "\(item.caseId) scope"
                )
                layers.append(
                    RequestPreferenceLayer(
                        scope: scope,
                        override: try Self.makeOverride(layer.override, caseId: item.caseId)
                    )
                )
            }
            let resolved = RequestPreferenceResolver.resolve(layers: layers)
            #expect(ExpectedResolution(resolved) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Selection Cases")
    func selectionCases() throws {
        let cases = try Self.preferenceContract().fixtures.selectionCases
        #expect(cases.count == 6)

        for item in cases {
            let intent = RequestSelectionIntent(
                availability: try #require(
                    RequestControlAvailability(rawValue: item.intent.availability), "\(item.caseId)"
                ),
                selection: try #require(
                    RequestPreferenceValueMode(rawValue: item.intent.selection), "\(item.caseId)"
                ),
                access: try #require(
                    RequestConnectionAccess(rawValue: item.intent.access), "\(item.caseId)"
                )
            )
            let decision = RequestPreferenceResolver.evaluateSelection(intent)
            #expect(ExpectedSelection(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Conflict Cases")
    func conflictCases() throws {
        let cases = try Self.preferenceContract().fixtures.conflictCases
        #expect(cases.count == 4)

        for item in cases {
            var assignments: [RequestPointerAssignment] = []
            for assignment in item.assignments {
                assignments.append(
                    RequestPointerAssignment(
                        owner: try #require(
                            RequestPreferenceOwner(rawValue: assignment.owner), "\(item.caseId)"
                        ),
                        pointer: assignment.pointer
                    )
                )
            }
            let decision = RequestPreferenceResolver.validateAssignments(
                assignments, declaredConflicts: item.declaredConflicts
            )
            #expect(ExpectedAssignment(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Safe Overlay Cases")
    func safeOverlayCases() throws {
        let cases = try Self.preferenceContract().fixtures.safeOverlayCases
        #expect(cases.count == 12)

        for item in cases {
            var declaredOwners: [String: RequestPreferenceOwner] = [:]
            for (pointer, owner) in item.intent.declaredOwners {
                let parsed: RequestPreferenceOwner = try #require(
                    RequestPreferenceOwner(rawValue: owner), "\(item.caseId) declaredOwners"
                )
                declaredOwners[pointer] = parsed
            }
            var operations: [RequestOverlayOperation] = []
            for operation in item.intent.operations {
                operations.append(
                    RequestOverlayOperation(
                        owner: try #require(
                            RequestPreferenceOwner(rawValue: operation.owner), "\(item.caseId)"
                        ),
                        op: operation.op,
                        pointer: operation.pointer,
                        value: operation.value
                    )
                )
            }
            let intent = RequestOverlayIntent(
                channel: item.intent.channel,
                metrics: RequestOverlayMetrics(
                    bytes: item.intent.metrics.bytes,
                    depth: item.intent.metrics.depth,
                    nodes: item.intent.metrics.nodes
                ),
                declaredOwners: declaredOwners,
                operations: operations
            )
            let decision = RequestPreferenceResolver.validateOverlay(intent)
            #expect(ExpectedOverlay(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Tool Contribution Cases")
    func toolContributionCases() throws {
        let cases = try Self.preferenceContract().fixtures.toolContributionCases
        #expect(cases.count == 4)

        for item in cases {
            var contributions: [RequestToolContribution] = []
            for contribution in item.contributions {
                contributions.append(
                    RequestToolContribution(
                        owner: try #require(
                            RequestPreferenceOwner(rawValue: contribution.owner), "\(item.caseId)"
                        ),
                        target: contribution.target,
                        operation: contribution.operation,
                        identity: contribution.identity
                    )
                )
            }
            let decision = RequestPreferenceResolver.composeContributions(
                base: item.base, contributions: contributions
            )
            #expect(ExpectedContribution(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Result Cases")
    func resultCases() throws {
        let cases = try Self.preferenceContract().fixtures.resultCases
        #expect(cases.count == 7)

        for item in cases {
            let facts = RequestResultFacts(
                wireApplied: item.intent.wireApplied,
                providerAccepted: item.intent.providerAccepted,
                evidenceKinds: item.intent.evidenceKinds,
                recovered: item.intent.recovered ?? false
            )
            let classification = RequestPreferenceResolver.classifyResult(facts)
            #expect(ExpectedResult(classification) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Continuation Cases")
    func continuationCases() throws {
        let contract = try Self.preferenceContract()
        let cases = contract.fixtures.continuationCases
        #expect(cases.count == 15)

        var covered = Set<String>()
        for item in cases {
            let intent = RequestContinuationIntent(
                kind: item.intent.kind,
                variant: item.intent.variant,
                step: item.intent.step,
                state: item.intent.state
            )
            let decision = RequestPreferenceResolver.validateContinuation(intent)
            #expect(ExpectedContinuation(decision) == item.expect, "\(item.caseId)")
            if item.expect.accepted { covered.insert(item.intent.kind) }
        }
        #expect(covered == Set(contract.vocabulary.continuationKinds))
    }

    @Test("Retry Cases")
    func retryCases() throws {
        let cases = try Self.preferenceContract().fixtures.retryCases
        #expect(cases.count == 9)

        for item in cases {
            var owner: RequestPreferenceOwner?
            if let raw = item.intent.owner {
                let parsed: RequestPreferenceOwner = try #require(
                    RequestPreferenceOwner(rawValue: raw), "\(item.caseId) owner"
                )
                owner = parsed
            }
            let intent = RequestRetryIntent(
                source: try #require(
                    RequestRetrySource(rawValue: item.intent.source), "\(item.caseId) source"
                ),
                status: item.intent.status,
                errorClass: item.intent.errorClass,
                owner: owner,
                locatedPointers: item.intent.locatedPointers,
                preToken: item.intent.preToken,
                streamStarted: item.intent.streamStarted,
                sideEffects: item.intent.sideEffects,
                automaticRetryCount: item.intent.automaticRetryCount
            )
            let decision = RequestPreferenceResolver.resolveRetry(intent)
            #expect(ExpectedRetry(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Every Preference Case Is Consumed")
    func everyPreferenceCaseIsConsumed() throws {
        let fixtures = try Self.preferenceContract().fixtures
        let counts = [
            fixtures.resolutionCases.count,
            fixtures.selectionCases.count,
            fixtures.conflictCases.count,
            fixtures.safeOverlayCases.count,
            fixtures.toolContributionCases.count,
            fixtures.resultCases.count,
            fixtures.continuationCases.count,
            fixtures.retryCases.count,
        ]
        #expect(counts == [5, 6, 4, 12, 4, 7, 15, 9])
        #expect(counts.reduce(0, +) == 62)
    }


    @Test("Runtime Envelope Cases")
    func runtimeEnvelopeCases() throws {
        let cases = try Self.shapeContract().fixtures.runtimeEnvelopeCases
        #expect(cases.count == 5)

        for item in cases {
            let decision = RequestPreferenceResolver.validateRuntimeEnvelope(payload: item.payload)
            #expect(ExpectedEnvelope(decision) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Control Resolution Cases")
    func controlResolutionCases() throws {
        let shape = try Self.shapeContract()
        #expect(shape.fixtures.controlResolutionCases.count == 19)
        try Self.assertControlCases(shape.fixtures.controlResolutionCases, shape: shape)
    }

    @Test("Reasoning Intent Cases")
    func reasoningIntentCases() throws {
        let cases = try Self.shapeContract().fixtures.reasoningIntentCases
        #expect(cases.count == 10)

        for item in cases {
            let capability = try #require(
                RequestPreferenceOwner(rawValue: item.capability), "\(item.caseId) capability"
            )
            let validation = RequestPreferenceResolver.validateAvailableIntents(
                capability: capability, intents: item.intents
            )
            #expect(ExpectedIntents(validation) == item.expect, "\(item.caseId)")
        }
    }

    @Test("Provider Universe Cases")
    func providerUniverseCases() throws {
        let shape = try Self.shapeContract()
        let cases = shape.fixtures.providerUniverseCases
        #expect(cases.count == 16)
        try Self.assertControlCases(cases, shape: shape)

        var covered = Set<String>()
        for item in cases {
            covered.insert(item.providerKind)
            for (capability, expected) in item.expect.results {
                #expect(expected.valid)
            }
        }
        #expect(covered == Set(shape.providerKindUniverse.kinds))
    }

    @Test("Exemption Negative Cases")
    func exemptionNegativeCases() throws {
        let shape = try Self.shapeContract()
        #expect(shape.fixtures.exemptionNegativeCases.count == 3)
        try Self.assertControlCases(shape.fixtures.exemptionNegativeCases, shape: shape)
    }


    private static func assertControlCases(_ cases: [ControlCase], shape: ShapeContract) throws {
        let sourceIndexKeys = Set(shape.fixtures.sharedSourceIndex.keys)
        let definitionOwners = shape.fixtures.sharedControlDefinitions.mapValues(\.owner)
        for item in cases {
            let providerKind = try #require(
                RequestProviderKind(rawValue: item.providerKind), "\(item.caseId) providerKind"
            )
            var controls: [String: RequestCapabilityControl] = [:]
            for (key, control) in item.capabilityControls {
                controls[key] = RequestCapabilityControl(
                    state: control.state,
                    recipeRef: control.recipeRef,
                    reasonCode: control.reasonCode,
                    sourceRefs: control.sourceRefs,
                    availableIntents: control.availableIntents,
                    customControlRefs: control.customControlRefs
                )
            }
            let resolution = RequestPreferenceResolver.resolveCapabilityControls(
                providerKind: providerKind,
                controls: controls,
                availableRecipeIDs: Set(item.recipes),
                sourceIndexKeys: sourceIndexKeys,
                controlDefinitionOwners: definitionOwners
            )
            #expect(
                resolution.unknownCapabilities == item.expect.unknownCapabilities.sorted(),
                "\(item.caseId) unknownCapabilities"
            )
            var actual: [String: ExpectedControlDecision] = [:]
            for (capability, decision) in resolution.results {
                actual[capability.rawValue] = ExpectedControlDecision(decision)
            }
            #expect(actual == item.expect.results, "\(item.caseId) results")
        }
    }

    private static func makeOverride(
        _ fixture: OverrideFixture,
        caseId: String
    ) throws -> RequestPreferenceOverride {
        switch fixture.state {
        case "inherit":
            return .inherit
        case "omit":
            return .omit
        case "value":
            return .value(try #require(fixture.value, "\(caseId) value state is missing value"))
        default:
            throw CocoaError(.formatting)
        }
    }


    fileprivate struct ExpectedResolution: Decodable, Equatable {
        let state: String
        let value: RequestPreferenceJSONValue?
        let source: String
        let reason: String?

        init(_ resolved: ResolvedRequestPreference) {
            state = resolved.override.stateToken
            if case .value(let payload) = resolved.override { value = payload } else { value = nil }
            source = resolved.source.rawValue
            reason = resolved.reason?.rawValue
        }
    }

    fileprivate struct ExpectedSelection: Decodable, Equatable {
        let allowed: Bool
        let reason: String?

        init(_ decision: RequestSelectionDecision) {
            allowed = decision.allowed
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedAssignment: Decodable, Equatable {
        let accepted: Bool
        let reason: String?

        init(_ decision: RequestAssignmentDecision) {
            accepted = decision.accepted
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedOverlay: Decodable, Equatable {
        let accepted: Bool
        let reason: String?

        init(_ decision: RequestOverlayDecision) {
            accepted = decision.accepted
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedContribution: Decodable, Equatable {
        let accepted: Bool
        let identities: [String]?
        let reason: String?

        init(_ decision: RequestContributionDecision) {
            accepted = decision.accepted
            identities = decision.identities
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedResult: Decodable, Equatable {
        let state: String
        let requested: Bool
        let observed: Bool

        init(_ classification: RequestResultClassification) {
            state = classification.state.rawValue
            requested = classification.requested
            observed = classification.observed
        }
    }

    fileprivate struct ExpectedContinuation: Decodable, Equatable {
        let accepted: Bool
        let reason: String?

        init(_ decision: RequestContinuationDecision) {
            accepted = decision.accepted
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedRetry: Decodable, Equatable {
        let retry: Bool
        let action: String

        init(_ decision: RequestRetryDecision) {
            retry = decision.retry
            action = decision.action.rawValue
        }
    }

    fileprivate struct ExpectedEnvelope: Decodable, Equatable {
        let applied: Bool
        let action: String
        let reason: String?
        let chatContinues: Bool

        init(_ decision: RequestRuntimeEnvelopeDecision) {
            applied = decision.applied
            action = decision.action.rawValue
            reason = decision.reason?.rawValue
            chatContinues = decision.chatContinues
        }
    }

    fileprivate struct ExpectedControlDecision: Decodable, Equatable {
        let valid: Bool
        let state: String
        let action: String
        let reason: String?

        init(_ decision: RequestCapabilityControlDecision) {
            valid = decision.valid
            state = decision.state.rawValue
            action = decision.action.rawValue
            reason = decision.reason?.rawValue
        }
    }

    fileprivate struct ExpectedIntents: Decodable, Equatable {
        let valid: Bool
        let reason: String?
        let intents: [String]

        init(_ validation: RequestReasoningIntentValidation) {
            valid = validation.valid
            reason = validation.reason?.rawValue
            intents = validation.intents
        }
    }


    fileprivate struct PreferenceContract: Decodable {
        let contractId: String
        let version: Int
        let owners: [OwnerFixture]
        let vocabulary: VocabularyFixture
        let resolution: ResolutionFixture
        let safeOverlay: SafeOverlayFixture
        let typedContributions: TypedContributionsFixture
        let continuation: ContinuationFixture
        let retryPolicy: RetryPolicyFixture
        let fixtures: PreferenceFixtures
    }

    fileprivate struct OwnerFixture: Decodable {
        let id: String
        let namespace: String
    }

    fileprivate struct VocabularyFixture: Decodable {
        let overrideStates: [String]
        let valueModes: [String]
        let controlAvailability: [String]
        let connectionAccess: [String]
        let continuationKinds: [String]
        let resultStates: [String]
        let observationEvidenceKinds: [String]
    }

    fileprivate struct ResolutionFixture: Decodable {
        let scopePriority: [String]
        let missingMeans: String
        let terminalStates: [String]
        let numericZeroIsExplicitValue: Bool
        let lastWriteWins: Bool
    }

    fileprivate struct SafeOverlayFixture: Decodable {
        let inputType: String
        let pointerSyntax: String
        let segmentPattern: String
        let blockedSegmentsRecursive: [String]
        let forbiddenChannels: [String]
        let builderOwnedRootFields: [String]
        let typedContributionOnlyRoots: [String]
        let limits: LimitsFixture
    }

    fileprivate struct LimitsFixture: Decodable {
        let maxBytes: Int
        let maxDepth: Int
        let maxNodes: Int
        let maxOperations: Int
    }

    fileprivate struct TypedContributionsFixture: Decodable {
        let targets: [String]
        let allowedOwnerByTarget: [String: [String]]
        let operations: [String]
    }

    fileprivate struct ContinuationFixture: Decodable {
        let kinds: [String: ContinuationKindFixture]
    }

    fileprivate struct ContinuationKindFixture: Decodable {
        let maxSteps: Int
        let requiredStateFields: [String]
        let opaqueReplay: Bool
        let variants: [String]?
    }

    fileprivate struct RetryPolicyFixture: Decodable {
        let automaticRetry: Bool
        let allowedStatus: Int
        let allowedErrorClass: String
        let requiresLocatedOwner: Bool
        let requiresLocatedPointers: Bool
        let explicitResendAction: String
        let savedPreferenceAfterRejection: String
        let neverAutomatic: [String]
    }

    fileprivate struct PreferenceFixtures: Decodable {
        let resolutionCases: [ResolutionCase]
        let selectionCases: [SelectionCase]
        let conflictCases: [ConflictCase]
        let safeOverlayCases: [OverlayCase]
        let toolContributionCases: [ContributionCase]
        let resultCases: [ResultCase]
        let continuationCases: [ContinuationCase]
        let retryCases: [RetryCase]
    }

    fileprivate struct ResolutionCase: Decodable {
        let caseId: String
        let owner: String
        let layers: [LayerFixture]
        let expect: ExpectedResolution
    }

    fileprivate struct LayerFixture: Decodable {
        let scope: String
        let override: OverrideFixture
    }

    fileprivate struct OverrideFixture: Decodable {
        let state: String
        let value: RequestPreferenceJSONValue?
    }

    fileprivate struct SelectionCase: Decodable {
        let caseId: String
        let intent: SelectionIntentFixture
        let expect: ExpectedSelection
    }

    fileprivate struct SelectionIntentFixture: Decodable {
        let availability: String
        let selection: String
        let access: String
    }

    fileprivate struct ConflictCase: Decodable {
        let caseId: String
        let assignments: [AssignmentFixture]
        let declaredConflicts: [[String]]
        let expect: ExpectedAssignment
    }

    fileprivate struct AssignmentFixture: Decodable {
        let owner: String
        let pointer: String
    }

    fileprivate struct OverlayCase: Decodable {
        let caseId: String
        let intent: OverlayIntentFixture
        let expect: ExpectedOverlay
    }

    fileprivate struct OverlayIntentFixture: Decodable {
        let channel: String
        let metrics: LimitsMetricsFixture
        let declaredOwners: [String: String]
        let operations: [OverlayOperationFixture]
    }

    fileprivate struct LimitsMetricsFixture: Decodable {
        let bytes: Int
        let depth: Int
        let nodes: Int
    }

    fileprivate struct OverlayOperationFixture: Decodable {
        let owner: String
        let op: String
        let pointer: String
        let value: RequestPreferenceJSONValue?
    }

    fileprivate struct ContributionCase: Decodable {
        let caseId: String
        let base: [String]
        let contributions: [ContributionFixture]
        let expect: ExpectedContribution
    }

    fileprivate struct ContributionFixture: Decodable {
        let owner: String
        let target: String
        let operation: String
        let identity: String
    }

    fileprivate struct ResultCase: Decodable {
        let caseId: String
        let intent: ResultIntentFixture
        let expect: ExpectedResult
    }

    fileprivate struct ResultIntentFixture: Decodable {
        let wireApplied: Bool
        let providerAccepted: Bool
        let evidenceKinds: [String]
        let recovered: Bool?
    }

    fileprivate struct ContinuationCase: Decodable {
        let caseId: String
        let intent: ContinuationIntentFixture
        let expect: ExpectedContinuation
    }

    fileprivate struct ContinuationIntentFixture: Decodable {
        let kind: String
        let variant: String?
        let step: Int
        let state: [String: RequestPreferenceJSONValue]
    }

    fileprivate struct RetryCase: Decodable {
        let caseId: String
        let intent: RetryIntentFixture
        let expect: ExpectedRetry
    }

    fileprivate struct RetryIntentFixture: Decodable {
        let source: String
        let status: Int?
        let errorClass: String
        let owner: String?
        let locatedPointers: [String]
        let preToken: Bool
        let streamStarted: Bool
        let sideEffects: Bool
        let automaticRetryCount: Int
    }

    fileprivate struct ShapeContract: Decodable {
        let contractId: String
        let version: Int
        let wireNaming: WireNamingFixture
        let providerKindUniverse: ProviderUniverseFixture
        let controlStates: [String]
        let stateRequirements: StateRequirementsFixture
        let reasoningIntents: ReasoningIntentsFixture
        let webIntents: WebIntentsFixture
        let failSafe: FailSafeFixture
        let fixtures: ShapeFixtures
    }

    fileprivate struct WireNamingFixture: Decodable {
        let runtimeEnvelopeKey: String
        let runtimeSchemaVersion: Int
        let runtimeEnvelopeFields: [String]
        let perModelControlsKey: String
        let capabilityControlKeys: [String]
        let recipeReferenceKey: String
    }

    fileprivate struct ProviderUniverseFixture: Decodable {
        let count: Int
        let kinds: [String]
    }

    fileprivate struct StateRequirementsFixture: Decodable {
        let nonAutoMinSourceRefs: Int
        let sourceRefExemptions: [ExemptionFixture]
        let fixedVerdicts: [VerdictFixture]
    }

    fileprivate struct ExemptionFixture: Decodable {
        let providerKind: String
        let state: String
        let reasonCode: String
    }

    fileprivate struct VerdictFixture: Decodable {
        let providerKind: String
        let state: String
        let reasonCode: String
        let autoRecipeAllowed: Bool
    }

    fileprivate struct ReasoningIntentsFixture: Decodable {
        let values: [String]
        let availableIntentsOnlyOnCapability: String
    }

    fileprivate struct WebIntentsFixture: Decodable {
        let values: [String]
        let availableIntentsOnlyOnCapability: String
    }

    fileprivate struct FailSafeFixture: Decodable {
        let actions: [String]
        let unknownControlState: String
        let danglingRecipeRefDegradesTo: String
    }

    fileprivate struct ShapeFixtures: Decodable {
        let sharedSourceIndex: [String: RequestPreferenceJSONValue]
        let sharedControlDefinitions: [String: ControlDefinitionFixture]
        let runtimeEnvelopeCases: [EnvelopeCase]
        let controlResolutionCases: [ControlCase]
        let reasoningIntentCases: [IntentCase]
        let providerUniverseCases: [ControlCase]
        let exemptionNegativeCases: [ControlCase]
    }

    fileprivate struct EnvelopeCase: Decodable {
        let caseId: String
        let payload: [String: RequestPreferenceJSONValue]
        let expect: ExpectedEnvelope
    }

    fileprivate struct ControlCase: Decodable {
        let caseId: String
        let providerKind: String
        let recipes: [String]
        let capabilityControls: [String: ControlFixture]
        let expect: ControlExpectation
    }

    fileprivate struct ControlFixture: Decodable {
        let state: String
        let recipeRef: String?
        let reasonCode: String?
        let sourceRefs: [String]?
        let availableIntents: [String]?
        let customControlRefs: [String]?
    }

    fileprivate struct ControlDefinitionFixture: Decodable {
        let owner: String
    }

    fileprivate struct ControlExpectation: Decodable {
        let unknownCapabilities: [String]
        let results: [String: ExpectedControlDecision]
    }

    fileprivate struct IntentCase: Decodable {
        let caseId: String
        let capability: String
        let intents: [String]
        let expect: ExpectedIntents
    }

    @Test("the compiler consumes shared fixture and preserves nested owned delta")
    func ownedPatchCompilerFixture() throws {
        let fixture: [String: Any] = try Self.loadRawContract("owned_patch_compiler.v1.json")
        #expect(fixture["contractId"] as? String == "owned_patch_compiler.v1")
        for raw in try #require(fixture["cases"] as? [[String: Any]]) {
            let operations = try #require(raw["operations"] as? [[String: Any]]).map { item in
                RequestOverlayOperation(owner: try! #require(RequestPreferenceOwner(rawValue: item["owner"] as! String)), op: item["op"] as! String, pointer: item["pointer"] as! String, value: item["value"].map(Self.jsonValue))
            }
            let owners = try #require(raw["declaredOwners"] as? [String: String]).mapValues { RequestPreferenceOwner(rawValue: $0)! }
            let base = try #require(raw["base"] as? [String: [Any]]).mapValues { $0.map(Self.jsonValue) }
            let contributions = try #require(raw["contributions"] as? [[String: Any]]).map { item in RequestToolContribution(owner: RequestPreferenceOwner(rawValue: item["owner"] as! String)!, target: item["target"] as! String, operation: item["operation"] as! String, identity: item["identity"] as! String, value: item["value"].map(Self.jsonValue)) }
            let conflicts = (raw["declaredConflicts"] as? [[String]]) ?? []
            let result = RequestPreferenceResolver.compileOwnedPatches(overlay: .init(channel: "body_fragment", metrics: .init(bytes: 32, depth: 2, nodes: 2), declaredOwners: owners, operations: operations), declaredConflicts: conflicts, base: base, contributions: contributions)
            let expected = try #require(raw["expect"] as? [String: Any])
            #expect(result.accepted == (expected["accepted"] as! Bool))
            #expect(result.reason == expected["reason"] as? String)
            if let delta = expected["delta"] { #expect(result.delta == .object((delta as! [String: Any]).mapValues(Self.jsonValue))) }
            if let preview = expected["preview"] { #expect(result.preview == .object((preview as! [String: Any]).mapValues(Self.jsonValue))) }
        }
    }


    private static func preferenceContract() throws -> PreferenceContract {
        try loadContract("request_preference_contract.v2.json")
    }

    private static func shapeContract() throws -> ShapeContract {
        try loadContract("request_shape_contract.v2.json")
    }

    private static func loadContract<T: Decodable>(_ fileName: String) throws -> T {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("model-contracts")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: candidate))
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func loadRawContract(_ fileName: String) throws -> [String: Any] {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent("shared").appendingPathComponent("model-contracts").appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func jsonValue(_ value: Any) -> RequestPreferenceJSONValue {
        if let value = value as? [String: Any] { return .object(value.mapValues(jsonValue)) }
        if let value = value as? [Any] { return .array(value.map(jsonValue)) }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .int(value) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? String { return .string(value) }
        return .null
    }
}
