import CryptoKit
import Foundation

struct WalletCredentialSafetyFinding: Equatable, Sendable {
    enum CredentialKind: Equatable, Sendable {
        case recoveryPhrase
        case privateKey
    }

    enum Reason: Equatable, Sendable {
        case publiclyKnown
        case predictablyWeak
    }

    let credentialKind: CredentialKind
    let reason: Reason
}

enum WalletCredentialSafetyService {
    static func finding(
        for draft: WalletImportDraft
    ) -> WalletCredentialSafetyFinding? {
        switch draft.secret {
        case let .recoveryPhrase(mnemonic, _, _):
            return recoveryPhraseFinding(mnemonic)
        case let .privateKey(data, _, _):
            return privateKeyFinding(data)
        case let .bitcoinImportedWallet(material):
            return material.sources.lazy.compactMap { privateKeyFinding($0.descriptor.key) }.first
        case let .muunRecovery(material):
            return privateKeyFinding(material.userPrivateKey)
                ?? privateKeyFinding(material.muunPrivateKey)
        }
    }

    static func recoveryPhraseFinding(
        _ mnemonic: String
    ) -> WalletCredentialSafetyFinding? {
        let normalized = normalizedMnemonic(mnemonic)
        let digest = fingerprint(Data(normalized.utf8))

        if publishedRecoveryPhraseFingerprints.contains(digest) {
            return WalletCredentialSafetyFinding(
                credentialKind: .recoveryPhrase,
                reason: .publiclyKnown
            )
        }

        let words = normalized.split(separator: " ").map(String.init)
        guard hasPredictableWordPattern(words) else { return nil }
        return WalletCredentialSafetyFinding(
            credentialKind: .recoveryPhrase,
            reason: .predictablyWeak
        )
    }

    static func privateKeyFinding(
        _ privateKey: Data
    ) -> WalletCredentialSafetyFinding? {
        if publishedPrivateKeyFingerprints.contains(fingerprint(privateKey)) {
            return WalletCredentialSafetyFinding(
                credentialKind: .privateKey,
                reason: .publiclyKnown
            )
        }

        guard hasPredictableBytePattern(privateKey) else { return nil }
        return WalletCredentialSafetyFinding(
            credentialKind: .privateKey,
            reason: .predictablyWeak
        )
    }

    private static func normalizedMnemonic(_ mnemonic: String) -> String {
        mnemonic
            .decomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func hasPredictableWordPattern(_ words: [String]) -> Bool {
        guard words.count >= 12 else { return false }
        let counts = Dictionary(grouping: words, by: { $0 })
            .mapValues(\.count)
        let highestFrequency = counts.values.max() ?? 0
        return counts.count <= max(2, words.count / 4)
            || highestFrequency >= words.count - 2
    }

    private static func hasPredictableBytePattern(_ bytes: Data) -> Bool {
        guard bytes.count == 32 else { return false }
        let values = Array(bytes)

        if values.prefix(24).allSatisfy({ $0 == 0 }) {
            let suffixValue = values.suffix(8).reduce(UInt64.zero) {
                ($0 << 8) | UInt64($1)
            }
            if suffixValue > 0, suffixValue <= 65_535 {
                return true
            }
        }

        return [1, 2, 4, 8].contains { period in
            values.indices.allSatisfy { index in
                index < period || values[index] == values[index % period]
            }
        }
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // SHA-256 fingerprints of every Trezor BIP-39 vector in the pinned corpus,
    // documented Anvil, Hardhat, and Ganache
    // development credentials, and public credentials reported to Aperture.
    // Raw recovery phrases are intentionally not bundled with the app.
    // Sources:
    // https://github.com/trezor/python-mnemonic/blob/
    // b57a5ad77a981e743f4167ab2f7927a55c1e82a8/vectors.json
    // https://www.getfoundry.sh/anvil/index.html
    // https://github.com/NomicFoundation/hardhat
    // https://github.com/ConsenSys-archive/ganache
    private static let publishedRecoveryPhraseFingerprints: Set<String> = [
        // Reported to Aperture on 2026-09-16: a leaked phrase whose TRON account
        // had its owner permission moved to another key.
        "ea98286901cd4b5ca3905d59c3bc832e6cc84b87bc793e510104fc0609acd110",
        "0912db95ceeb5368381b44ac3158096f78a80f69c405216f01220dd87768202c",
        "0f388b04e512d7a0eda5889c96ff034cf63499b73898965a8e187e3a8a25d198",
        "15f41342748aa6c0718a6f4fa4e153acf61aa4dc073a6e77347fa2e4ef639162",
        "29aedb051d65bcc80e3379acb13afb2a0807f5f4bbb346a9846c056720e0a7cd",
        "30452ba5605dd25289bc2ae7b1883a53b1cece62e2331fa105b88c9682dd37c7",
        "341c225b06c91708aa82ab8389075a8227fda76fb2b9cae2d445e36ca8c44da1",
        "3a64bcd9cea43c0aba67ba0bf2ddff8137a492bccbc672107fcbf7381086f698",
        "3b1c5e02107409ea60548d8d8f686fd8d722791f3618deb1f9eb1e9f5c02cd35",
        "3c0949435a7e4277fac2fbe27975cdd9f5b5abf94d282112eaf4cebbb8560984",
        "662c451cc5886e1d6f185f418b815a175bfd197536556607272b36fdefa8c969",
        "69be79ef3c28f55d7cb84db2dd3c18dfff45eeefebd09b8c5f7f3489b8ba09ac",
        "6d828debd306e21a02511899832f7ee5591de0693b2f2bd78967fb1e09bafdbb",
        "867f9f5929a7201c1116579e17be6ce501f8a8c5a8d0d1ac7173d72ae78fd945",
        "a5fe1cb4158ffd2a27ae93b5ac617903504c3ec9d8f6ac9737ecc207cb460e72",
        "b12ee277a669b18fb7c5d9d3642c9298ce06f0814a4166a6396ad9cb2eccc914",
        "b1bff22ae077ce1ae482e4dcb01c144ff8a44e97fbb3f3a5f62567f4ac19da7c",
        "b2e71100d10bee74156b69806498a2e3d90e432160c2e266465ba669a220d50b",
        "b8ae5c99142647d1043595539d615197ee7dad5e7c031d5447e78c69e62ba01f",
        "c1db187b992c8ddddbe9dfab0e88542e9af36e1816c0d4c70353cd1175159bd9",
        "c557eec878dfd852ba3f88087c4f350f09c55537ab5e549c3cd14320ec3cef38",
        "cc95a8a1b5e9bf130a4468b1b4857b6a7fc64979970a06b806cb879460d15348",
        "d6da54d12db9eac818868b841c1c9cc7c39f5294c8620ad24b7715b7820febc0",
        "e770e8aa42a869cf269a5bda331f706a08e02a6223ffbd28d71580e2101e02a4",
        "e96bfc1d78867126dadff72e64807301e9bb837bcf329c86976647e529520528",
        "ecb0e7ba498c5920991f0b3483e91f7abafa9ecc6bd82a9a51494589592b1a8f",
        "f79cd64f9cea237897b8133e4b905b361c6f166faa5a1c64c32280938f5b707e",
        "0077e530fb26ec84490ad157cb7f334d427032a8ebe28257bf8a721056e8dd07",
        "008669332b47b170a101f338f0b67ea5545f6ea9dc7936503a816c4a343480ae",
        "0206a568f16783f73b92bf79288eed8b364d9ed248cec302061cf7a1f6092cef",
        "0345fb67a840bca6151ba90221d6065f6e147729b90a216c53408add1fba6cd6",
        "05ce605145cab2580f4e1c1cb39b463592ad38a4695b93b5306f46207894898c",
        "06ce65b019de0223b53965b53b0de1e880bae089f416e7e2345cf2d81f076f06",
        "076594db01d6c0534b6c5dba3bc5aec98e9ca931af32b407e3b3acc5a3c56a0e",
        "09cd3fdb579df1fd1da57aee3bd799c7f4a57d8f866c71b90f756e5e1da26d34",
        "0b2de5800fec011867a96e63b539e8de94b729ef3bb6fed068f78590ccd1d48f",
        "0b6ed377ae2f0916b9a10bdee0270078575da8dde29947174a559377771f3a21",
        "0cbc9f3e92a246a7a5c92f7a7c74e2e3032e01ae97db9e6b9aac940998b25b4c",
        "0d34635f6c54586459bd00c0609c6e1504b73875135aced3664ee10c8768f72e",
        "0d4ce981339ad054f668c44eadb4ee3dcf42425799ad5db8235d08eae6310e13",
        "10478ca57b513cc9f61893fea25953dca9f956a6709c717e37ee65777febd76e",
        "117ee62ec6c5f9020a8b501ccb437464cd78238b0ca720db940b7dfd97d8e082",
        "1200915d142be1e30db536e0e01299b1babaa605f7e8425ac0bb1dd8458b30a4",
        "12c40af6aec1f3edb8b85dd23449bd4e63b1493ca6d4d8bc50bc8eecc61e33fc",
        "12e659198031560e2612e87e9bd6c36202e4cf94cb2b2faccad14aac196c0495",
        "1341a0ac8ae857da88cc7aa5527c2318df65383f83c0f162d87379b82622cfe3",
        "135f974da97d2d47a03ffd690642898cae2450f0380873ff1c1aa956fd9534e8",
        "1517473d53ab56bb8116d605686ffb00dc1b54ee18308746c2aaa5ffdba517f9",
        "176c2bdcdfeb8fb703c3fbda7a32a04399b00bf14a0d12a9ea7aa24fa734fa41",
        "18b61e31aa4520bb27a8bd1c3e841eaccc43732bfd25fd511a240a06f839f272",
        "196540ab310a334623c05c4bad989b3c0d7ded0d8e5d3d65391373e5c022ddc9",
        "1a6308cfcffcc652066bbd2c8229f98f3e8c0ede632075a6b71bade137da2cf2",
        "1b463121aed01b45c40790fce89dd9308c6c17345fb92df9a3a0d806e8634b11",
        "1be919984b9b8e55a7b5248d701c4425db4d441443f42961daf6b97fc91becf3",
        "1d8661fc792bf8b4988e77336a0369b90714485306999b2e852ac45cffdb1f32",
        "1e43d91b25f7065ac2922bdc2ae7ceb9df2add0bd266cd63781f6cd738fcaeb0",
        "1e43f6c61542586190d48a21de712c04aa21c7c5945feede7ac0ff3a9c252bca",
        "20b15111271e32da9c8df2d3bd63b954d10b7c21d8e85403c57b0e1771ed62f7",
        "222cbf8ade455d1613abcd299cebcc374ecdd5ac9dd8aabc489978228db2b38d",
        "22b170e5df6395cc98d3e0f0ebd9fc761506a5d0dfeb576c316e3eb8c6a6d2f9",
        "2591017e68d54cdc75406149ebead1f795b3a62481aeafce21903b3f7543f46a",
        "267c91f6ec6ace4f03fb490a7a3762a3fa6e2ffa80a4bb75abefe96156350355",
        "26b6c150a229d555c006189846faf660534a693132d074265a261e47d07c8abd",
        "26cfb1b6e911e848b6453672532584d70c08255c86e9a6e27c25e557f168c0cf",
        "281284ad50633d48461bbd32f721ccf346f24bfb977e999ac814511cf9ab7aeb",
        "299107964a8dc79ff80c2e538827e4bbd2eb5d4d5d5cafbc19569af527e475eb",
        "2b256fd50563f1f3edab3c861de47d7e8aaf453953a239a6d04b3cf0986e6814",
        "2cb029e44cec2d7033e2ad3f8a20c4d8ce77eb311f3416819f4231e8491154fb",
        "2e7ee9b3dc5a289909a5601f1c7a98a4833a027891fd01edc80fe1e9aa544ba9",
        "2eae192f6da4741c337e119a92d8502e2237a376f8541fcab5c2554b02887978",
        "30d78d94e3fec9de0183e3a54291258fc8dfbe386f54fe28b7902ba133dd801f",
        "31610089d848d24a424e297437a5a2fdc6c67d735d738949c12a7b38fc5eca20",
        "326b3d2da1d10acaad15e867371ab543a3a35fc5ef2ec61a1e79383bde377f3e",
        "3b7fe334982dd28c298e341b2c28165dc80e9db2c3032a0ece6664e0dcee0da4",
        "3d71444cf8aa6315958850e489e63eb3c35d38e2017bb01cbc2ed6cec252ded5",
        "3e970311e1c7cfef107ae7a784d8f2d90e142688f9701935437ccf6b25234aa5",
        "3e9f3d648644f3e7adb2eb3a3c6fad19c3483ec1a9ea1eec1af07ec4dbea935a",
        "3f6eacd9d9956499a1678617a1e0d36c326f76a8a3324303911203f381cb3fb5",
        "3fce2adfd467202a33708b6db8ade7c46e757141a7753f93623c9c0a7ffc7c01",
        "41dadfb8c5ba20fa7cb74a14de445e63d4a035071bdb183963021ae674f3640a",
        "451a9ecc83acabb5157244428d479d0eb21ac0b4166a7b470c7d009e87e935f3",
        "48cd076b7f898bf8c045787be3d72e5a7a531cf58e8616a5238980fcb0a5b742",
        "4ae0afe164148b2bf9a4ad5a2f5ef470d96bc23c01ce9aac977b704f0e40b2dd",
        "4bbfcf65046767982233249da522688ab3c66688a848e7f745cc16d48d8620c6",
        "4c6ebc0a56486718ebe39661f478ae708e3a25202e18cc7694f0114be23e5b42",
        "4cfe8c0610d8f865b7326fde2263f21c726aae26402c1e20e531602e63222971",
        "4d41f3d7f53d48096daec905a8416ee97797555799e3b3269a9eaeaaf1cc49fd",
        "4ddb6456727714dda60e0bdd8bc00be79396f9aa5df718862de8d2ff93d0c405",
        "50716348cf06da6d3b90d2bf7c2298eb701c8286fe2e00140c605bc30412e25d",
        "50efa535fa80e84cf6516a3ff55d93af9ffe38e1958aab241857953ac72e9c65",
        "52a89168f465824183c2d094e7fa25505e02b3d326fb5900b58ef02e33cbbe9a",
        "5571947686c01dc6de663fef4c1d7568fb10f7d4aa3ea58c069ecdfa65c7753d",
        "55b773e86ff553129858f7f4b4017c04e03e899db4aac9c849dbdc208774e581",
        "565cb0e81691905638d86c05d1843746fa79d32b9f93a0133f1cff5c3579e7db",
        "5708b9bae0000dc1ed5e0a70581908e90022f01376cd1c40a923cc1808629033",
        "596a4dabd84e135677db791c4b38cddd324adf2cade861d7d1cfb4aa13ccd53f",
        "5d18f5729d57c9ca214dc0e032da0242cd6bdf84a722519bb346db92b55b4a5c",
        "5d791754a9bb6dd20377ba38a5d6f62b051f30b1cd7d602e24435f2e2caafca9",
        "5dc601e6d8d083dd14c802cbdd5b8de4905b2f7f801bab8f31a02d3ab6bacee5",
        "5ee1c5e575d2c6583eb9a4122db67aedf8113471e196faad707bf2cf41e1ca89",
        "5f9e655598b79f380fb80ea1a4b007050e57d9bfed29d489dd8544f3bbbedc6f",
        "60e1b949844a1a367550a6a08df740d03306484e798df82b79a8b034bf27e6dd",
        "61066981f0bf0cfdaaf879ba2ee1044f26098a66c185c56419e9771e72ce7627",
        "61347d852559d23932dbc41e8e8c4ea124f774b0553535e92edab78fde432b37",
        "61c0c7ff68a37ec34a3ad28e5ce709a55defedb56a7aa7ee3a44ffaa8838324b",
        "6268a112a5a40547ff2ad9cf6bf57a194bd4300ba92603d4d22efaa94d80cfb5",
        "653a97655ab3e49288a62280b9414d9cff913bf09a0211821851c5b764b231d0",
        "656a20232ad11d33b572628df72ff058e64741ccdb5e5946bb3eab18b8b7e3bd",
        "657992ca287f56f1084cc439bec79d0513ebc47c6a28018a669d52655b699b92",
        "66e8d47ec7571ab865af90cc3af8958ad9819a6e72cc0e35d947a7957155e08e",
        "67d928fbc97421b5731af4e2cac70686b09794de89be5b845c46f7885e0d1a63",
        "68428f26f49f96d085ed65f9318ec39ba5ead9cfde889ec5b7f70192080a690e",
        "6961d15f4baf8d22539f66a083b79fb0c5abf0d268b0de1fcea0931e56d81634",
        "6bb027e1b87827f7af17cf1a3a22d1153cf51a6bbe9f6a5681cc97df108352b8",
        "6cf017cca6a15f1d13f71911e1a790cfaf0023e0956409220a996554c9a14eef",
        "6dbc3f55a49366463d810026b7aa8cb626ac8973b5d234265ceef3ca46938793",
        "6e6c1591c8dbe5d8c7718884d600de1f33320a9736328447091462a0c0593f20",
        "6f80d5720e48ec18489c884931cd0faf141daaf65795fe79feb973e9bd06a6eb",
        "6ff55d1bf8d29ff04fde1a73affc8fa146d860c370304b632ab480479fed81c8",
        "70ead54e5846ac8e41c69d7702819e232d97a5cd705bfa1c86eaea0f114a2919",
        "722d9f21e042f7294284c0fb49986541a49a0ed6399a25dbda7bb6cf0a1dd348",
        "740165f7f9a02b94f761f97664775ea6bca6c5600267b9938551b2b4922ab794",
        "7571379a07dc7c0f699665f43477353c89aa80036f9b66a33e79cbce612cd1e2",
        "75dffde7950027d7031d4546761ce9d556109ecfb1c1d0f92ca03b109c44c538",
        "77e2e792965f216b601d5a4adf3eec876a38b5632a125aa8b4cd04662822a971",
        "783ef6bd3cfdd85fcf3e30e498e066ca303f8369353b01046cadc27aa1a0a94b",
        "7a0169547b383ee04d7c1f7b1fd0e08a70d7f1d343c651093376bc265a87112f",
        "7a19b466c67492880d5a3f25e6f4bc086da53accd8f54323ff3bf3e155be2a4d",
        "7bc6a4413ee9eed8474dae0fd2860c42e76736380e44b30d99d9be7c975cec3d",
        "7c12b1f409f58f0ff19017270bc9a3cd210b0e1193d0177eaf40c98f3f06e28a",
        "7d2d06f5dda5b3a299f295b0c294c817c247fd6deee9c23313d8f6c635480d5b",
        "7f8097aa37aad8be6b0b4175e86adf8b8d57e8913afcdb956cd57ecf4b286b66",
        "7fed8e3e06f182b7c18144be72014e584b075916bb912f7429aa54491bd58b94",
        "815f46ef34b5ce1497ba416a0a1a1e2cd6ddb9ae5611a2b38551735a8653f71a",
        "833f9d68c4fc4bf04aefd47b597eafa85ed0d59b24db63ca646d776a925ccc29",
        "839d9269172486b79a0a3ca87c98937097074e754b6b2e168d0ef758f16301a2",
        "84b73a8522e9cff505ef1a8f009e899587140fbe8c26268497a0a17182cb1dea",
        "85f97624db808d076567c3f9eaeb00a429b786e37fccba585bc924dd0ac4d9c8",
        "87182376c1bd05f5081a0470ed9dd02573e9cb1d3aca5c4c6ac4a3e0a7ea3ea8",
        "8798038692436ad2e5206ec29db6e27b7d87ec9e0b0d86d707c252cd3ee40c9b",
        "87ec799c43c8f4111ebf9ab4eea8ec9d147c5d2e738e7cf039776a3f025d558c",
        "894f792052f15ee16d8670636964f8bcf2e89f8fd1d4321fa9a80f180f188259",
        "89dc007554078320a1654fd504aecbcb17fab0404e6ab29a3d15f1a58fa5d31e",
        "8b804d091093aa076c2933058c9a4775aa783321de31239281a0cec0c797e5d7",
        "8ca3722598662dbaacedc86568d3a23376ab517fbc6f0135fe96b04bc10a70c0",
        "8cabc13fa6b17486dcd24fac3692312a6979c8766ba76532679167b20c099cd9",
        "8d038f1cf27a981a2f769d42dc5028962c72e434b79a1407a2981976e7f12342",
        "8e17d9c0e7ff79d5238df122aa48c74ab03f78ae89fed1928ece94c6a3885608",
        "901c1f82ae10d5fdc85597024c29ae00015a7f50188146b1ef0005cbc2bbb5ee",
        "92c7fe71d1c8459654bb7120037ac6dc6f568c0b923677a976cafab0571eb31e",
        "92e48ff8a9d7b95c3194c532a4f87b1a0fd579dc8aec4c9b51abdca7a0e84b77",
        "94fde755c8570a56ec841dff0b59d93a3b51648b5d741b6944f5cbc2d6327e85",
        "9581011933e343a7f5f92611dc02cfb551c4f96b4a6b7aca4c1fd50616d48d0b",
        "97d363f710e231cd71051ead662a984e2fbabe4e7d325fef6f7250264b3fb83b",
        "9af142e90ae231cb6bcc3deed23376cfcf2b6b8a8e182cda58ab3300fcae58c1",
        "9b1229b22d51b691f8b74df99874dde3bd67cc4733d2feb3a96bcee1b8aa7de3",
        "9c35df442fbbbe0bcfdf31c96d007987e3ddac6dd5be9f6f1a87ed00d969b4cb",
        "9c5d0a6656e5d3f36601d0bf98762be09bad5d7b164382c1d6c826324d6d599a",
        "9d3561a21bf7cabc42b705479acead7f6d14dfd1fef324b9627bb99961e6c1ec",
        "9d8f3852111cffa7e2b2fc4e53e068273f1fcc6b352dd708314e6253b23e0cc7",
        "9ec14eb2712b26a1d64ae7462ea3a022bb6ef476423749651ff74caa11cebfe8",
        "a270ac35eab58e0c3ad8c426f9df7da68cca3d969df340a14582f5cffe1fc44c",
        "a2edcc61b60223350dbeb0f28dc9344a20dc743605b00e03b16d9b2bb9aebc8d",
        "a35b6d4655d93a4cc9801be64dea3c26780ff8552e9ff26b233f11541334e0b2",
        "a41cecf931a28d35ca267e6429eef3e02f9a383a6c5da196e99fb342ebcc0e86",
        "a44204609e15db391e8ad90181731e7bdf511dc2f513d43cc05517ce2085647d",
        "a590235c1ac23da751cdfa981e2c6370470a5bd5d0656d48b56c80981205b2e6",
        "a6758b5a88c0df30c573879d2e909e9bae86c5ba4d5bf6c7568760884f71f897",
        "a68d01e777b7bf149d8a723fc533fcc762797921254658cbe03df2df4ecb2d15",
        "a87195c258f2bc23ae488afee011beddcd5092d0ff57123bb2c837d511229bc8",
        "a90de040eb916d3669776bfeedeecc63b45f0989bab05de796e5f59b01a5c6e1",
        "aa9f315e4261ddaeb400ebb4c57f9ed1f3f85ed0554a34531878cbbe7c67ab01",
        "aaf5fb92120c003d3b34985597e9758bf3b546b482af12bd233c0a5afabaf1aa",
        "ad170b79c89b98ffcebc0089cb7b5c8d227e139c42d88ab61a3a15ed45366df2",
        "ae816caca72b002ba032539c499f26fbfd477c5f966c9c6fe371b9cf9cfcea7c",
        "aebb4f07b7c222f502535f383427ad3d96a5ad1a30016b338fbee8723d12fb74",
        "aed92b904399995011f20b5be26b9dada713aa92587feb5083b3be2aabbb98e3",
        "aff9112b73e812cfe51d0f33ef1f7abeae39c385d840187add53fb0f89116ee7",
        "b19820f31e28a4a081a15de5cb449ed496d332c8ffd1d90e8d8fdac04a155b49",
        "b1a6d59d7bdec6cb3d579211027455f69351393bc832a820a0bc86e5dbba9ef5",
        "b380b7030c8478034e9f5505c8a60bd68b1045ba1b95cf06fcad1c85b5393394",
        "b3caa071aaef1c233cbf6121dcf995c72a97b0ad4e35c048f00a4e08d9655c4c",
        "b42c7297bec97315ef3136897673d33f21b4dcb26f497ac5cb4b8d49823d7162",
        "b52de4bb178f54825187c994b830fd7311e9078c1afcd6230b3e4983d084b9bd",
        "b5c0405ca19e143eb1b54e5dd16ff2383fabb9b07faf831fc60b0de11c011dcf",
        "b6bce763df8e10d77e3b381de7739d04bab1655378ac4decc7312c805d97a312",
        "b83e96417f61cb148d0dc8a89b839ee4956ad45b5e4b6a2a6cae048e48782157",
        "bbdeb0693905c315c04e3c9566677dd85a13b405a4c513a7c2889fc8aa7ac1ee",
        "bbfb5709d26a5761c76f6221e45fcc0f811bf38bd72993504d99c470f1fbd05b",
        "bd6352df4a359aed1934ae2a875a2c91deb90eaa83372984b6920f7e6ea98b6e",
        "c028f5b64f7ec3a126dd3143bad383391d7d3cc361c8c8b8e59b000003d28486",
        "c051e749bc0ed1839ccdf2948e4ba3907dc106b11a3a9a993646d776d74a132b",
        "c08f97c6361a901599a3b24724d1086e40d6d0479bfe9aa6899aba5796ce35e9",
        "c1e64df73912cbd554000a9aeb8e7610e3d4987caeed6ee1d8edac062657194c",
        "c252a9053a43b6bdca5ba05ad6f082c2ccfcbb467cb89e8f9c6928ee7e20c440",
        "c35e1153a278854590fc735dddba05bdf080f98d376fc74605ff679dbc0bf796",
        "c662bea2c970ffaac425e29929a90b155af9ec3353c9c5b11a25f35aaa9c5eeb",
        "c6cabf5ab3ca29594fee1259de46c0cb8d1e6a25dede133fa6bf86cfd1ab9c1e",
        "c87c3870783e3426c97eded1b6bc465c548ed60b961d0358f144ebcfa47263bf",
        "c98db6dc49d3ef9f106025d746414b4d328beb5c1e92edf09b40947a9f852fca",
        "c9a5d407779c7fc1499e2eb3cb9d594c573c4a64c6c37fafa2b2b1afd0f047a7",
        "cb3af8394d98b6f1e5e479ca27449f83de15b099c4925f7ab8191329dfc6dfa9",
        "cbd491ee55033fca0d70326770684c82cff49480ac0870714df56b0630cb36f4",
        "cc0d36a749cd6eba86c7c50e55158589c526e53fc4efd7760ffc789c37290f44",
        "cca9ef66ce170869ae11e92d9f50c661f07c18a3e0ad34a623d0799a943b50e1",
        "ccdc2328787f49d60c83d74566d7924886b68cc6accfce9ac767df91c8eca705",
        "cdb0450764cc65897c651445946bddb319045d54cd910f2b79b405b1bfc6be60",
        "d27da48db408be1b7ac31a8575d12b4e2a9df11c4f4c7b22e1c88fa2d27b4873",
        "d3720f00b030a86c4ad18226766e0295b5b8704452f9d4688f0bb78094b0ee51",
        "d37d38dc25f76f73ef129cd336bffe8b7b6a817cc8ad616096f052ebd69b7aff",
        "d476322203078ab4c9914748943ee6d82da403470eeb6a5d56c417c4f82ec384",
        "d7cef6aa1545304da7fd17360852dbca2b2f834fcea1e570e7c2201aea63937d",
        "d901a7761f608ffdf880a30754c71ea1e13cf74bc2d1655bbc2ef3cdab530467",
        "d97e8bce8409995d9b74a3d24e950382ef1d04654eeb9d0d84518fc4e82e1198",
        "d9f10038e567bf27379cab0e91245952880b4f7ddd3d6d82f15c9e9b745033ac",
        "db2459a0e075e5da0543883d0e4d135bc7260995d6c5d717a01bac50338f3bde",
        "dcbd4be83193e2e2102f5ee0253ced56dc1c0ef513acc2f4bab1ae47fb207755",
        "dd221e53c03e583c35d21abc9eca5b8ef2b90c6c1e3385f48e3bef52a67b3735",
        "ddb2f89e975aa3aebbfbbca237d375f8d58f0e529dba29ce816f1a1794fd7650",
        "ddc596c516344314f064f08b492e41c80679ff315fbf8668ace790562d9eb45b",
        "ddd0151393d97be2291b3bcd1a84133bb5e59c50fac1141dc1049eef3eeb2388",
        "e566253b2591545642006fa80f8c06bc44f8b591ea5c36037bfa50350056f062",
        "e5aad11e050b6c9701187b6385572fff863b7a971fefc0d2c319497ae424d45e",
        "e5c4da01fb5c7aca63c65961f756286d251edad75f764773ba876aa765a3b201",
        "e6a03b167578e0e5223d8500f2e28e70915fd3d1dbedf481c4a107131ead984d",
        "ebc1fabf92c44a566f0d3df8a43fcd0c9b2da7e0db1c0fd89c455598c55fdfe8",
        "ebdc4e7441ae2949efbb14919ec3075a1451d8a4535fde2d071e268b2c522efd",
        "ec8cde717f14c4b76d2d8801ae6e66579c2ec90fee088cab03cd085b452d63c5",
        "ecab2196b92c8f4ffc10975ed383cdff245debdaba4791653140a2879f9db0c8",
        "ee24b4550cb6e5e9be13b48886c2c085d4daf97e07a39fb2b45feddf0fe6101a",
        "ef32f3f743ce5ed9acf6aa4c7fc2e7f610916a56ae0a8f50380368f62eabdd6d",
        "f413b452b0eceb754af62672f38742e6b13422fbb58e893b82da982a9d163b28",
        "f43a0058979cb095df1c0f96ab81c51a4cf1e40648cb999167e2f6a16f4bb67c",
        "f48437020cf3f2de2da674df6bd52cbfb40f542710a0dc9d032d7fbae917e278",
        "f4a58525ee29a795b8647668481327e8e5213aae8ff7855c86dd009e82cd2bb0",
        "f56485434fd41e37a24af63662775a18989297996c2c54a4733b0aedd7036868",
        "f57a463b3084157eed787ea9e51b757ac4045fc33be4aaa9f50f6e31f9d7c17d",
        "f6c82f05025f5d49a73687fe423f9a874be8a93759aaef905527bb3896235155",
        "f7a4ea9c046b178cd696369bb2d896c0dc26881ee5b783792bac72c0d3ecaf53",
        "f884bc2d04c38ecc7afe990cbc3915b31c0b2d1f8a7f2a7530f79296557d2ddf",
        "f9355e58f70974dc0254727f02378b158a04bc14cc7400a3514bbb6607cc308d",
        "fb4f1b7e99a329380460570cb883cf3e1d9c551da67c2815c2315d053e733071",
        "fe26bba9fe467f1a25aef2a172547034e22137b40b274e665a49cd35933325f6",
        "0094d4bf4b0df88192bf10ad7d09423dfab10cea025818685da6e0925b73d62a",
        "0385bdc296fbd060bd876789bc6bf7ab1222258992c930cacc53e6ee3f3806ca",
        "059d2ad1f6d7537d8d3e1d7236deccf5083d56c8378818c9db80d6210dcdcc59",
        "0938ec71fe2fb2ba047d83d42d04c80c1ece86bc9098f244905535a523bf566a",
        "2e45bd083d7c041bc547b6469fe0431ff43a7b003148f1fd706b07022b2f5c44",
        "387649bfbfe67f66e4dfaaec243600b34fba01ea1446a9a57c097b1879491e50",
        "3c9501e40641c38e891dd5996a6f005486bfa8330407f602e9870c2127125017",
        "4acfb8add98dfad7a374c7a23c343b4e43a86a712eb82ead6e93471cdae055c2",
        "4b8c5eddf97ca5b9fe9b89b5fd9613607d9366891a2c7915bb0b6e7b505d2ea0",
        "782b007c5a331f4b64aee7000aeea0cdf1b921e662e4d4564d91fc9949cf82fb",
        "904b9b1eec66e15be17144e407893dedc88cd0d3fbec4d5936a33cbb5bdb8b46",
        "945f856066815d025a5bd4dfc10a14be617c6e3f7e2e244af3b47c87f4c36fc4",
        "98313a56a82a19f19669200ba7cb9252e97ade257ea6d6800ba8d97713c09b65",
        "9ea271df4b91094d34b69c51e141df02ba7d406902afcd297f4fa77cab773e1b",
        "a01b174ad31deefc920e2f14a27196c0f5c670893ad552acf99b7d0a99fa289d",
        "a7401b85c74f9f285f370ccb1b6234df95cf4960cc7feaa70e0f382d44f00ec8",
        "b2e09634b363a878989a413c65bd69d44ecdaacab66af6141233ecfa00a00c5f",
        "c08b47e5f6291ea3275a25885baef25662a275744994e1852acdbcc081bd2c81",
        "c8beb7fe1d00a52de132a93e6557a0de94d7b20d57b14f6f4524128c30796d63",
        "d4d384950f817e3637b1bc9fd957b73a48002f957c4348ea6fa221b8a213c93b",
        "dd0a1c423a3d2aa8f22c03ea64a1ea4a3d16eb962ca4768a8f55286766932bd1",
        "e15cffa131cc968cfbe266fc2e6b7cebe779c78ebd61b110d4e3cf36b471d0d2",
        "e6a44726543c9d9d72902f29b5d4c95394b39df265409ce7be75a7baf6bfab81",
        "fd959d5f978c706231cbcee68a6b3d2fb0899c6b1c9c3f41fd93c8de4eeb0cb1",
        "22c3cbcda95969db5d1a280264e68cd1211186cac71f89dd59f8fb9ee219919c",
        "235f73c2c2afab497ac9a46db164980528098ef918c0df344a69348362c6e01c",
        "370291bf3f474715969c6a162113acae1a32f7ea748f38e3fba2b4b2a62d6a6e",
        "3a094fee30dbb669e24e1482670217d77a3655366ba6f957751c493c03dfd88a",
        "50dc5d676b1a1c2a4209a7ed81504b79232cbff6e30acccd443a3c6a2a934d94",
        "5f65b18d0f7c41065c1c0024c8081e4896ee528ce32878ec5dfe0a7e780eef20",
        "612d2b127d11fb1adf77e3a14d51b38b16bfec530720224de644037b4eec8d31",
        "6e477827b273b53b03b05ba14bf9601e4174f70be40698ed93e8cc1f89e9c976",
        "70c86f569a2f9efdacb31f45794b899db69e8619f5f605322201166aba9e6ded",
        "752a64b0c13b652d0d2bf1469606047fa27359f18914db890ea3e645ee5f91c5",
        "8d4a0a15d26ca5f4174cc944335f497fb9e1ac22ac684077c52219f27e4c67db",
        "8d582e2e9366dc4d212e51bff68c208f826b6765c4423ef4c379fedd12821aa4",
        "9a64fe9ca6d5f2916e920fc66305f6cbb3a19e7a6a72727128b2781e42bf47a1",
        "a3c112fde4a21d93c0d348694ca8d1001fdb35b0ba49023f599944eaaa2173c0",
        "a970c84dd403fdd56088f3ecfceaacacda0413902e6ae94e05e019736a4d7472",
        "cb320c41adf55085d5243310c604ebbd9ddb7c87c97d4cc8db5158d381c466a2",
        "d0cfd8b36841fcb15ac8e29d4f91ef75430f2d716c36066bbf94a9965bc67aa1",
        "d271b0943618123c74f7ffa0b5bee1bdae92f0c45b7d3dcd60d7591943680ead",
        "e82a8c3bbae98731a08fc79e89a403765cf37de4a4273a10d77f83c2b7d46a60",
        "ea042f621f48ddd3266173e3adf037978f2607d5efdeb57127a5253b1df0884d",
        "f036b2373a47b6fa5818f960fa80f40e425dc76308d2c06a56c7997b6c65b737",
        "f0c51b215dbf9bbcfecb93cebf7b42e962d38a0ebb3b81609716d75e3ab56870",
        "f5b0e5df4e8e71c55fa6147b6e2b7290266708a1f9b3737ecaf36fab8e98f350",
        "f7b9f94c83713c6d21d0899f031df74eda7db678ac14fb6b26c1077ec2e9ab2b",
        "60b5ac8eec69b9f8b329f3fdb46b420ba14b48bb6caa3c9ef7256f397d018056"
    ]

    // SHA-256 fingerprints of canonical 32-byte private keys from documented
    // Anvil, Hardhat, and Ganache development accounts, plus public private
    // keys reported to Aperture. Raw private keys are not bundled with the app.
    private static let publishedPrivateKeyFingerprints: Set<String> = [
        // Reported to Aperture on 2026-09-16 alongside the leaked phrase above.
        "f061d402d14b7302d149999bb29462e849f145de7824a69c2a7d112ef519280c",
        "193ae84c4c9567c25105535802f463f3f8dc420b0ce9a5b57c7931c764e623d6",
        "25061aad2bb0917814989eb38f95608a744ecb8173fdce329486e8b83086e5f0",
        "2d1831e800ec18fe3e29da2e4357db936efce5b9792d76683d465582f0910db0",
        "59891c96881dfbcf7d2ddc270b7813e666694fbbffe8ddd2736bf91c1b0e85d4",
        "59ad99d565557cc0968550ed2f5ea5ff5fd1d279324a25d324a531053c9c16a3",
        "6718ba8966161cc843e01e8d19f018859e1bcba7f0e8f2c108578b497ac408b7",
        "93e372c67f7238faf2dfdc029246b299e88d71937680cbb895fedeb2a262ed19",
        "ac29b3735d1b57180dea890d6321cd27e593723cbe9e227eed8a3fa35945122c",
        "bca4c2c0761d850f0c403a699280f70f86ab6659a611ada431019203cd66098f",
        "e25a680eff8baac7b15129a830ecc40211017919d5d32fce8c6b409af753e50f",
        "0bf58c494765047505db29453fc7670f3db2ec0569a65ceada3a6885ed840fac",
        "3407c1890d719a17f23a247fdc0b1118ceac4cb4f446d0706e9ae74537790087",
        "34ec71e14eadf154cdb138050821fd206703cf5794e7923c91261b82b50ff4a5",
        "433b2e1dfcf07cc1e3d285105499559efacf6bf15b4c517fee45213e9e1e4018",
        "4998ff08a7813035e34bb18483a549edb8761542a05766da72610eb9cf651b4f",
        "49b7a6a8b8a6392aaf6c0c65eb1d91c5a59c4c54810b1c499c554d10d163bfaa",
        "4a95cb3ba84ec6441755562ec20130c6dd1b5332f39f5b22ca54db4bbcab4f48",
        "5683701095df12728836f7ba836c2564831da3603e268729faec85be23d770bd",
        "5a801427c8b7be628c8bf3d8f75645ab8b74fe966b95e0d1f1ec61193bdccec7",
        "69b8f3f9f4e2873cb8bc59d25457987dc4fa72fb5de42790e2cac96ca5460124",
        "77b8a0f88a30eba7875035fbdfc6d8457cebbcc965f0cb70cda2873a408efbe2",
        "7ebf8ed1e0c24a0a425901cd07eb35a983eae17e802f7c0ab148a8cbe2ba091f",
        "a5088b88526dfdbec48ef5de7adb6274164d18a166704daf18f8c4f4aecb2618",
        "b3146d642538d2809dac859c969b09a27a651bcaaa4080c2a9c9a9d28f74e2b1",
        "c065f5ffb9bb9a195ce5b0424fb632f416c2d745f795cb5c06fe91aed17cac24",
        "cf5f090ef5ad175dd734642ea43e8167dd84a25a0820da5922788a686e380e95",
        "d79f6da7f0e6e3858aa9dfd4d3c881ae08ad5ee4f3cfcb66cdef5a30ffae7189",
        "dddb340ae3e6a05f1be8e2f8e065affe874895f694f126da01ad344cfee83402",
        "dfc44dbc519c691c75166765461d7d9c22597a85da9a392eb110725c1b8cb49b",
        "f810d868d21fd8592334c8dea767a14f821dfd20488806a7743585fc64026e5f",
        "3d10abbc9c3e287bd2c89cd83cf1849b9368352fe9318823bb25cafd0aa23fbd",
        "6503803831c946cdadd00c0116828972f5dcdffa5f2417ea136f75eba8a58859",
        "74f97a55058da1bab0311ae9d2530606fd1aed2612b552886a4163a290633b63",
        "a9c85ef9ebbbe0685ca5c740e814b69797a557e0bdabd24e7363b2c72fa3f929",
        "ac70e04ef12b755b829661e0f57bd3349f0f006536b739f154212be4c1a7191f",
        "b8acf5d5eb4e7fd0b086cc02be9efbb57ced88c3528e151565341e685753cbee",
        "c188a572f30c631c29864a510a25759a260e95a52df2f83b89c64436411a5de2",
        "e77b7f2257fe244cec79340345d2044069e5544129acce4947388e67a6b26200",
        "ea72a3e7d4937af3e138d48889290ace71d6fa2c9846509efee3ff2483fbc8da",
        "fd375fcf38ac71dd90e0ff16ae924cd13bd9dd120a8b6135b3e63b87b8ff532f",
        "f061d402d14b7302d149999bb29462e849f145de7824a69c2a7d112ef519280c"
    ]
}
