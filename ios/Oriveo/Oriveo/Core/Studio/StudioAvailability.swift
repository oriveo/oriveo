import Foundation

/// Single source of truth for whether Studio is available. Every Studio entry point
/// (tab / sidebar, `oriveo://studio/*` deep links, badge, chat "open in studio",
/// managed image models in the chat picker) asks this and nothing else.
///
/// Truth table: `shared/studio-contracts/studio_availability.v1.json`, read by the
/// iOS / Android / Web contract tests alike. The Web-only `webApiStatus` has no iOS
/// counterpart.
enum StudioAvailability {
    /// Remote kill switch; missing means on (only used to hide in an emergency).
    static let remoteStudioEnabledKey = "studio_enabled"
    /// Remote switch for hosted image models; missing means off.
    static let remoteManagedEnabledKey = "studio_managed_enabled"

    struct Input: Equatable {
        var compileFlag: Bool
        /// `nil` = key missing from featureFlags, treated as `true`.
        var remoteStudioEnabled: Bool?
        /// `nil` = key missing from featureFlags, treated as `false`.
        var remoteManagedEnabled: Bool?
        /// Managed protection switch `image_disabled`.
        var imageDisabled: Bool = false
        var enabledManagedModels: Int = 0
        var isPro: Bool
    }

    struct Result: Equatable {
        var entryVisible: Bool
        var deepLinkOpens: Bool
        var badgeRendered: Bool
        var managedListed: Bool
        var managedInChatPicker: Bool
        /// Chat image works are always registered locally, regardless of the flags.
        var chatWorkRegistration: Bool
        /// Pro works sync regardless of the flags, so turning the entry on does not
        /// trigger a mass upload.
        var syncWorks: Bool
    }

    /// Build-time switch: on in Debug, off in Release until the shipping version.
    static var compiledIn: Bool {
        #if ORIVEO_STUDIO
        return true
        #else
        return false
        #endif
    }

    static func evaluate(_ input: Input) -> Result {
        let entry = input.compileFlag && (input.remoteStudioEnabled ?? true)
        let managed = entry
            && (input.remoteManagedEnabled ?? false)
            && !input.imageDisabled
            && input.enabledManagedModels > 0
        return Result(
            entryVisible: entry,
            deepLinkOpens: entry,
            badgeRendered: entry,
            managedListed: managed,
            managedInChatPicker: managed,
            chatWorkRegistration: true,
            syncWorks: input.isPro
        )
    }

    /// Maps `/api/metadata` `runtimeConfig.featureFlags` to an input. Missing keys stay
    /// `nil` so `evaluate` applies the contract defaults (not `false`).
    static func input(
        featureFlags: [String: Bool]?,
        compileFlag: Bool = compiledIn,
        imageDisabled: Bool = false,
        enabledManagedModels: Int = 0,
        isPro: Bool
    ) -> Input {
        Input(
            compileFlag: compileFlag,
            remoteStudioEnabled: featureFlags?[remoteStudioEnabledKey],
            remoteManagedEnabled: featureFlags?[remoteManagedEnabledKey],
            imageDisabled: imageDisabled,
            enabledManagedModels: enabledManagedModels,
            isPro: isPro
        )
    }
}
