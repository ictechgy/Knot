import Testing
import KnotNativeCore

@Test func physicalOwnershipReleasesAfterControlBeforeLetterAndPreservesRepeat() {
    var keys = PhysicalKeyOwnership()
    keys.press(59)
    #expect(keys.routesDown(8, textMode: true, shortcutModifier: true))
    keys.press(8)
    let controlUp = keys.release(59); #expect(controlUp)
    let cUp = keys.release(8); #expect(cUp) // C-up after Control-up still belongs to physical path
    let unmatched = keys.release(8); #expect(!unmatched)
    #expect(!keys.routesDown(8, textMode: true, shortcutModifier: false))
    let textOnlyUp = keys.release(8); #expect(!textOnlyUp) // a committed-text-only key never creates physical up
    keys.press(8)
    #expect(keys.routesDown(8, textMode: true, shortcutModifier: false))
    keys.press(8); keys.press(8) // repeat down stays forwarded, one ownership entry
    #expect(keys.count == 1)
    keys.reset(); let afterReset = keys.release(8); #expect(!afterReset && keys.count == 0)
}

@Test func physicalLetterBeforeControlUpAndKeypadMappings() {
    var keys = PhysicalKeyOwnership(); keys.press(59); keys.press(8)
    let cUp = keys.release(8), controlUp = keys.release(59); #expect(cUp && controlUp)
    #expect(WindowsScanCodes.map[76]?.0 == 0x1c && WindowsScanCodes.map[76]?.1 == true)
    #expect(WindowsScanCodes.map[75]?.0 == 0x35 && WindowsScanCodes.map[75]?.1 == true)
    #expect(WindowsScanCodes.map[36]?.0 == 0x1c && WindowsScanCodes.map[36]?.1 == false)
}

@Test func viewerLabelHasBoundedUTF8AndNoControls() {
    #expect(Invitation.validViewerLabel("개발 Mac"))
    #expect(!Invitation.validViewerLabel("") && !Invitation.validViewerLabel("Mac\nother"))
    #expect(!Invitation.validViewerLabel(String(repeating: "한", count: 22)))
    #expect(Invitation.validViewerLabel(String(repeating: "a", count: 64)))
}
