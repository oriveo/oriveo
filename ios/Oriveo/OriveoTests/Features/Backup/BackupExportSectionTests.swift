import Testing
@testable import Oriveo

@Suite("BackupExportSection")
@MainActor
struct BackupExportSectionTests {
    @Test("Export form validation allows export only when passwords meet length and match")
    func exportFormValidationRequiresMatchingPasswords() {
        var state = BackupExportFormState()
        state.includeKeys = false
        state.password = "short"
        state.confirmPassword = "short"

        #expect(state.canExport == true)

        state.includeKeys = true
        #expect(state.canExport == false, "Keys selected but password too short")

        state.password = "12345678"
        state.confirmPassword = "12345678"
        #expect(state.canExport == true)

        state.confirmPassword = "87654321"
        #expect(state.canExport == false, "Passwords must match even when long enough")
    }

    @Test("Password mismatch warning only appears when both password fields are filled and differ")
    func passwordMismatchWarningCondition() {
        var state = BackupExportFormState()
        state.includeKeys = true
        state.password = "12345678"
        state.confirmPassword = "87654321"

        #expect(state.shouldShowPasswordMismatchWarning == true)

        state.confirmPassword = ""
        #expect(state.shouldShowPasswordMismatchWarning == false)
    }
}
