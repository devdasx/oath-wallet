import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct BIP39MultilingualMnemonicTests {
    @Test
    func exposesEveryOfficialBIP39Language() {
        #expect(BIP39Mnemonic.supportedLanguages == BIP39Language.allCases)
    }

    @Test
    func exposesOrderedWordsAndExactElevenBitIndexes() {
        for language in BIP39Language.allCases {
            let entries = BIP39Mnemonic.wordEntries(for: language)
            #expect(entries.count == 2_048)
            #expect(entries.first?.index == 0)
            #expect(entries.first?.binaryIndex == "00000000000")
            #expect(entries.last?.index == 2_047)
            #expect(entries.last?.binaryIndex == "11111111111")
            #expect(entries.allSatisfy { $0.binaryIndex.count == 11 })
        }
    }

    @Test
    func completesTheCurrentWordWithinTheDetectedLanguage() {
        let matches = BIP39Mnemonic.matchingWordEntries(
            prefix: "ABAN",
            precedingWords: ["amount"]
        )

        #expect(matches.map(\.word) == ["abandon"])
        #expect(matches.allSatisfy { $0.language == .english })
        #expect(
            BIP39Mnemonic.candidateLanguages(for: ["amount", "liar"])
                == [.english]
        )
    }

    @Test
    func findsEveryChecksumValidLastWordForAllStandardLengths() {
        let vectors: [(
            precedingCount: Int,
            expectedLastWord: String,
            expectedCandidateCount: Int
        )] = [
            (11, "about", 128),
            (14, "address", 64),
            (17, "agent", 32),
            (20, "admit", 16),
            (23, "art", 8)
        ]

        for vector in vectors {
            let precedingWords = Array(
                repeating: "abandon",
                count: vector.precedingCount
            )
            let candidates = BIP39Mnemonic.lastWordCandidates(
                precedingPhrase: precedingWords.joined(separator: " ")
            )
            let englishCandidates = candidates.filter {
                $0.language == .english
            }

            #expect(
                englishCandidates.count == vector.expectedCandidateCount
            )
            #expect(
                candidates.contains {
                    $0.language == .english
                        && $0.word == vector.expectedLastWord
                }
            )
            #expect(
                englishCandidates.allSatisfy { candidate in
                    BIP39Mnemonic.isValid(
                        (precedingWords + [candidate.word])
                            .joined(separator: " ")
                    )
                }
            )
        }
    }

    @Test
    func findsTheKnownLastWordForEveryOfficialWordList() {
        for (language, fixture) in Self.fixtures {
            let words = fixture.phrase.split(separator: " ").map(String.init)
            let expectedLastWord = words.last ?? ""
            let candidates = BIP39Mnemonic.lastWordCandidates(
                precedingPhrase: words.dropLast().joined(separator: " ")
            )

            #expect(
                candidates.contains {
                    $0.language == language
                        && $0.word == expectedLastWord
                }
            )
        }
    }

    @Test
    func rejectsUnsupportedCountsAndWordsOutsideOneWordList() {
        #expect(
            BIP39Mnemonic.lastWordCandidates(
                precedingPhrase: Array(
                    repeating: "abandon",
                    count: 10
                ).joined(separator: " ")
            ).isEmpty
        )

        let mixedWords = Array(repeating: "abandon", count: 10)
            + ["not-a-bip39-word"]
        #expect(
            BIP39Mnemonic.lastWordCandidates(
                precedingPhrase: mixedWords.joined(separator: " ")
            ).isEmpty
        )
    }

    @Test("Chinese (Simplified)")
    func chineseSimplified() throws {
        try verify(.chineseSimplified)
    }

    @Test("Chinese (Traditional)")
    func chineseTraditional() throws {
        try verify(.chineseTraditional)
    }

    @Test("Czech")
    func czech() throws {
        try verify(.czech)
    }

    @Test("English")
    func english() throws {
        try verify(.english)
    }

    @Test("French")
    func french() throws {
        try verify(.french)
    }

    @Test("Italian")
    func italian() throws {
        try verify(.italian)
    }

    @Test("Japanese")
    func japanese() throws {
        try verify(.japanese)

        let fixture = try #require(Self.fixtures[.japanese])
        let ideographicSpacing = fixture.phrase.replacingOccurrences(
            of: " ",
            with: "\u{3000}"
        )
        #expect(BIP39Mnemonic.isValid(ideographicSpacing))
    }

    @Test("Korean")
    func korean() throws {
        try verify(.korean)
    }

    @Test("Portuguese")
    func portuguese() throws {
        try verify(.portuguese)
    }

    @Test("Spanish")
    func spanish() throws {
        try verify(.spanish)
    }

    @Test
    func rejectsMixedLanguagesAndUnsupportedWordCounts() throws {
        let english = try #require(Self.fixtures[.english])
        let french = try #require(Self.fixtures[.french])
        var mixedWords = english.phrase.split(separator: " ").map(String.init)
        mixedWords[5] = french.phrase.split(separator: " ").map(String.init)[5]

        #expect(!BIP39Mnemonic.isValid(mixedWords.joined(separator: " ")))
        #expect(!BIP39Mnemonic.isValid("abandon ability able"))
        #expect(!BIP39Mnemonic.isValid(""))
    }

    @Test
    func rejectsUnknownWordsAndInvalidChecksumsBeforeImport() throws {
        let unknownWords = "aurora beacon cobalt delta ember forest galaxy harbor island juniper kinetic lantern"
        let english = try #require(Self.fixtures[.english])

        #expect(!WalletCoreService.isValidRecoveryPhrase(unknownWords))
        #expect(throws: WalletCoreServiceError.self) {
            try WalletCoreService.importRecoveryPhrase(unknownWords)
        }
        #expect(!WalletCoreService.isValidRecoveryPhrase(
            english.invalidPhrase
        ))
        #expect(throws: WalletCoreServiceError.self) {
            try WalletCoreService.importRecoveryPhrase(
                english.invalidPhrase
            )
        }
    }

    private func verify(_ language: BIP39Language) throws {
        let fixture = try #require(Self.fixtures[language])
        let validation = try #require(
            BIP39Mnemonic.validation(of: fixture.phrase)
        )
        #expect(validation.language == language)
        #expect(validation.wordCount == 12)
        #expect(validation.normalizedPhrase == fixture.phrase)
        #expect(!BIP39Mnemonic.isValid(fixture.invalidPhrase))

        let precomposed = fixture.phrase
            .precomposedStringWithCanonicalMapping
        let normalizedValidation = try #require(
            BIP39Mnemonic.validation(of: " \n\(precomposed)\t ")
        )
        #expect(normalizedValidation == validation)

        let wallet = try #require(
            BIP39Mnemonic.hdWallet(mnemonic: precomposed)
        )
        #expect(Self.hex(wallet.seed) == fixture.expectedSeedHex)

        let importDraft = try WalletCoreService.importRecoveryPhrase(
            precomposed
        )
        guard case let .recoveryPhrase(mnemonic, passphrase, wordCount) =
            importDraft.secret
        else {
            Issue.record("Expected a recovery-phrase import draft")
            return
        }
        #expect(mnemonic == fixture.phrase)
        #expect(passphrase.isEmpty)
        #expect(wordCount == 12)
        #expect(!importDraft.address.isEmpty)
        #expect(!importDraft.publicKey.isEmpty)

        let bitcoinFamily = try BitcoinFamilyDerivationService().derive(
            mnemonic: precomposed
        )
        #expect(bitcoinFamily.count == BitcoinFamilyChain.allCases.count)
        #expect(bitcoinFamily.allSatisfy { !$0.address.isEmpty })
        #expect(bitcoinFamily.allSatisfy { !$0.publicKey.isEmpty })
    }

    @Test
    func passphraseMatchesTheOfficialBIP39VectorAndRoundTrips() throws {
        let mnemonic =
            "abandon abandon abandon abandon abandon abandon "
            + "abandon abandon abandon abandon abandon about"
        let credential = try WalletRecoveryCredential(
            mnemonic: mnemonic,
            passphrase: "TREZOR"
        )
        let wallet = try #require(credential.makeHDWallet())

        #expect(
            Self.hex(wallet.seed) ==
                "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553"
                + "1f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
        )
        #expect(
            try WalletRecoveryCredential.decode(
                credential.encodedData()
            ) == credential
        )
        #expect(
            try WalletRecoveryCredential.decode(Data(mnemonic.utf8))
                == WalletRecoveryCredential(mnemonic: mnemonic)
        )

        let withPassphrase = try WalletCoreService.restoreEVMWallet(
            mnemonic: mnemonic,
            passphrase: "TREZOR"
        )
        let withoutPassphrase = try WalletCoreService.restoreEVMWallet(
            mnemonic: mnemonic
        )
        #expect(withPassphrase.address != withoutPassphrase.address)
        #expect(withPassphrase.passphrase == "TREZOR")
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        let phrase: String
        let invalidPhrase: String
        let expectedSeedHex: String
    }

    private static let fixtures: [BIP39Language: Fixture] = [
        .chineseSimplified: Fixture(
            phrase: "的 三 欧 三 考 于 据 保 量 损 破 战",
            invalidPhrase: "的 三 欧 三 考 于 据 保 量 损 破 一",
            expectedSeedHex: "9859899437d054276ba8301d0a27b0c0c67c6e2863d68ed8d52e44c5ed9e0cc4132a5f6ba37c4ee8a2f2bbc498293a642c9ff497fff1f5f546cae2c165e0f089"
        ),
        .chineseTraditional: Fixture(
            phrase: "的 三 歐 三 考 於 據 保 量 損 破 戰",
            invalidPhrase: "的 三 歐 三 考 於 據 保 量 損 破 一",
            expectedSeedHex: "3fac393cf2327d761e8443b66f2c5bb22cc59278c5b906b07dfd0f8be91e56c7bc60038744b2a8d89844f8746686c32fbb6a9e195b5e1fe811c60dc050e8654b"
        ),
        .czech: Fixture(
            phrase: "abdikace bidlo obvykle bidlo kopnout bachor doma doprovod bojovat lobista kachna dokola",
            invalidPhrase: "abdikace bidlo obvykle bidlo kopnout bachor doma doprovod bojovat lobista kachna abeceda",
            expectedSeedHex: "01bff33895d6c09654dfef1bd3d22eb42d7f00c03cd8076d4cd79052b3131f23b0beecb2c8598834d68dcbba6354f10f690f7e5da562a0be9ef9e86ed8d13c0d"
        ),
        .english: Fixture(
            phrase: "abandon amount liar amount expire adjust cage candy arch gather drum buyer",
            invalidPhrase: "abandon amount liar amount expire adjust cage candy arch gather drum ability",
            expectedSeedHex: "3779b041fab425e9c0fd55846b2a03e9a388fb12784067bd8ebdb464c2574a05bcc7a8eb54d7b2a2c8420ff60f630722ea5132d28605dbc996c8ca7d7a8311c0"
        ),
        .french: Fixture(
            phrase: "abaisser agréable inductif agréable éligible achat bolide boucle amateur exister dérober bloquer",
            invalidPhrase: "abaisser agréable inductif agréable éligible achat bolide boucle amateur exister dérober abandon",
            expectedSeedHex: "b70232fad2698ee7236b5f789e1566157f41e9b0a22b4dfa0c3325172a6fd8513e0d552a12c335737275847d5b25a24bfaad97bdb4d98541901d3bd2a9cbfcf1"
        ),
        .italian: Fixture(
            phrase: "abaco alogeno mitigare alogeno fenomeno affetto bravura bronzina ampio gonfio elaborato bottino",
            invalidPhrase: "abaco alogeno mitigare alogeno fenomeno affetto bravura bronzina ampio gonfio elaborato abbaglio",
            expectedSeedHex: "e26a889ebae217f1115abd8d324d850927af0af43b42ed4c333b8962e1088f8ee6a829628cdbb1c70a4fd691aa6adeb40e631fc8cb3aa44746c361ba34e8be21"
        ),
        .japanese: Fixture(
            phrase: "あいこくしん いくぶん そなた いくぶん こぜん あぶら おおう おきる いたみ さんすう けたば おうたい",
            invalidPhrase: "あいこくしん いくぶん そなた いくぶん こぜん あぶら おおう おきる いたみ さんすう けたば あいさつ",
            expectedSeedHex: "8c62436b42e641181b155fcdb62af9dd960156b9ab6fbe58880174ce48a1d97fde3d43b622c2959fd437fd1ee1dcd96ccc4ca24dbd1317d770ac2bbfede5521f"
        ),
        .korean: Fixture(
            phrase: "가격 걱정 심부름 걱정 별도 갈색 기법 기운 경력 산길 미술 기념",
            invalidPhrase: "가격 걱정 심부름 걱정 별도 갈색 기법 기운 경력 산길 미술 가끔",
            expectedSeedHex: "c84d23b603720bc67db1b1f5f1cbfc82b760736ad8069bf283c8d5d2a5b1e2075e73208fbe8763500b572839ff3c7827917a7d8eec19b2732152f84b0ace5b70"
        ),
        .portuguese: Fixture(
            phrase: "abacate afivelar inativo afivelar donzela achatar barulho beber albergue exalar cuidado banir",
            invalidPhrase: "abacate afivelar inativo afivelar donzela achatar barulho beber albergue exalar cuidado abaixo",
            expectedSeedHex: "21eae7e0861e0fb828e7b5727992a1efaa90b16a58e4474924b1f58472c362b84abbb9cba83ea4f32cef178a9bb74f73feaa7a5ac2ad5df39eb7772c4f3a3b31"
        ),
        .spanish: Fixture(
            phrase: "ábaco álbum líquido álbum espuma acudir bolero bosque amante gaita dictar boca",
            invalidPhrase: "ábaco álbum líquido álbum espuma acudir bolero bosque amante gaita dictar abdomen",
            expectedSeedHex: "21d369cf994a9b2d99c938c979d9ca95ceeb7ac55589622bf57e2f53e7edf7688eb32a140ac9206dbf219376a8ffc7ecf4d642a88834a1dfb633d75a34180b60"
        )
    ]
}
