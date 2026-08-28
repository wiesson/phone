import Testing
@testable import Phone

@Test func importsExecutableModule() {
    #expect(CallState.ready.isReady)
}

@Test func insertsG722BeforeG711Once() {
    let original = "module\tstdio.so\n#module\tg722.so\nmodule\tg711.so\nmodule\tauconv.so\n"
    let updated = configEnsuringPreferredG722Module(original)

    #expect(updated.contains("module\t\t\tg722.so\nmodule\tg711.so"))
    #expect(updated.split(separator: "\n").filter {
        let fields = $0.split(whereSeparator: { $0.isWhitespace })
        return fields.count >= 2 && fields[0] == "module" && fields[1] == "g722.so"
    }.count == 1)
    #expect(configEnsuringPreferredG722Module(updated) == updated)
}

@Test func movesActiveG722BeforeG711() {
    let original = "module g711.so\nmodule g722.so\n"
    let updated = configEnsuringPreferredG722Module(original)

    #expect(updated == "module g722.so\nmodule g711.so\n")
}
