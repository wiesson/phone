import Testing
@testable import Phone

@Test func importsExecutableModule() {
    #expect(CallState.ready.isReady)
}

@Test func insertsOpusAndG722BeforeG711Once() {
    let original = "module\tstdio.so\n#module\topus.so\n#module\tg722.so\nmodule\tg711.so\nmodule\tauconv.so\n"
    let modules = ["opus.so", "g722.so"]
    let updated = configEnsuringPreferredAudioCodecModules(original, modules: modules)

    #expect(updated.contains("module\t\t\topus.so\nmodule\t\t\tg722.so\nmodule\tg711.so"))
    for module in modules {
        #expect(updated.split(separator: "\n").filter {
            let fields = $0.split(whereSeparator: { $0.isWhitespace })
            return fields.count >= 2 && fields[0] == "module" && fields[1] == Substring(module)
        }.count == 1)
    }
    #expect(configEnsuringPreferredAudioCodecModules(updated, modules: modules) == updated)
}

@Test func movesActiveOpusAndG722BeforeG711() {
    let original = "module g711.so\nmodule g722.so\nmodule opus.so\n"
    let updated = configEnsuringPreferredAudioCodecModules(original, modules: ["opus.so", "g722.so"])

    #expect(updated == "module opus.so\nmodule g722.so\nmodule g711.so\n")
}
