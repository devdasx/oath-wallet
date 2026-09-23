import Foundation
import Testing
import WalletCore
@testable import Aperture

@Suite(.serialized)
struct WalletCoreSigningParityTests {
    @Test
    func ethereumMainnetERC20EIP1559MatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // Ethereum/TWAnySignerTests.cpp `SignERC20Transfer_1559`.
        let gasLimit = try #require(Data(hexString: "0130b9"))
        let priorityFee = try #require(Data(hexString: "77359400"))
        let maximumFee = try #require(Data(hexString: "b2d05e00"))
        let privateKey = try #require(Data(hexString:
            "608dcb1742bb3fb7aec002074e3420e4f"
            + "ab7d00cced79ccdac53ed5b27138151"
        ))
        let amount = try #require(Data(hexString: "1bc16d674ec80000"))
        let output: EthereumSigningOutput = AnySigner.sign(
            input: EthereumSigningInput.with {
                $0.chainID = Data([1])
                $0.nonce = Data([0])
                $0.txMode = .enveloped
                $0.gasLimit = gasLimit
                $0.maxInclusionFeePerGas = priorityFee
                $0.maxFeePerGas = maximumFee
                $0.toAddress =
                    "0x6b175474e89094c44da98b954eedeac495271d0f"
                $0.privateKey = privateKey
                $0.transaction.erc20Transfer = .with {
                    $0.to =
                        "0x5322b34c88ed0691971bf52a7047448f0f4efc84"
                    $0.amount = amount
                }
            },
            coin: .ethereum
        )

        #expect(output.error == .ok)
        #expect(output.encoded.hexString ==
            "02f8b00180847735940084b2d05e00830130b9946b175474e89094c44"
            + "da98b954eedeac495271d0f80b844a9059cbb00000000000000000000"
            + "00005322b34c88ed0691971bf52a7047448f0f4efc8400000000000000"
            + "00000000000000000000000000000000001bc16d674ec80000c080a0ad"
            + "fcfdf98d4ed35a8967a0c1d78b42adb7c5d831cf5a3272654ec8f8bcd7"
            + "be2ea011641e065684f6aa476f4fd250aa46cd0b44eccdb0a6e1650d658"
            + "d1998684cdf"
        )
    }

    @Test
    func bitcoinMainnetMixedInputVectorMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // Bitcoin/TWBitcoinSigningTests.cpp `SignP2WPKH_Bip143`.
        let hash0 = try #require(Data(hexString:
            "fff7f7881a8099afa6940d42d1e7f63"
            + "62bec38171ea3edf433541db4e4ad969f"
        ))
        let hash1 = try #require(Data(hexString:
            "ef51e1b804cc89d182d279655c3aa89e"
            + "815b1b309fe287d9b2b55d57b90ec68a"
        ))
        let key0Data = try #require(Data(hexString:
            "bbc27228ddcb9209d7fd6f36b02f7dfa"
            + "6252af40bb2f1cbc7a557da8027ff866"
        ))
        let key1Data = try #require(Data(hexString:
            "619c335025c7f4012e556c2a58b2506e"
            + "30b8511b53ade95ea316fd8c3286feb9"
        ))
        let key0 = try #require(PrivateKey(data: key0Data))
        let key1 = try #require(PrivateKey(data: key1Data))
        let pubkey0 = key0.getPublicKeySecp256k1(compressed: true)
        let pubkey1 = key1.getPublicKeySecp256k1(compressed: true)
        let utxo0 = BitcoinUnspentTransaction.with {
            $0.outPoint = .with {
                $0.hash = hash0
                $0.index = 0
                $0.sequence = 0xffffffee
            }
            $0.script = BitcoinScript.buildPayToPublicKey(
                pubkey: pubkey0.data
            ).data
            $0.amount = 1_000_000
        }
        let utxo1 = BitcoinUnspentTransaction.with {
            $0.outPoint = .with {
                $0.hash = hash1
                $0.index = 1
                $0.sequence = UInt32.max
            }
            $0.script = BitcoinScript.buildPayToWitnessPubkeyHash(
                hash: pubkey1.bitcoinKeyHash
            ).data
            $0.amount = 600_000_000
        }
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: BitcoinSigningInput.with {
                $0.hashType = BitcoinSigHashType.all.rawValue
                $0.amount = 112_340_000
                $0.byteFee = 20
                $0.toAddress = "1Cu32FVupVCgHkMMRJdYJugxwo2Aprgk7H"
                $0.changeAddress = "16TZ8J6Q5iZKBWizWzFAYnrsaox5Z5aBRV"
                $0.privateKey = [key0.data, key1.data]
                $0.utxo = [utxo0, utxo1]
                $0.coinType = CoinType.bitcoin.rawValue
                $0.lockTime = 0x11
                $0.plan = .with {
                    $0.amount = 112_340_000
                    $0.availableAmount = 601_000_000
                    $0.fee = 265_210_000
                    $0.change = 223_450_000
                    $0.branchID = Data([0])
                    $0.utxos = [utxo0, utxo1]
                }
            },
            coin: .bitcoin
        )

        #expect(output.error == .ok)
        #expect(output.encoded.hexString ==
            "01000000000102fff7f7881a8099afa6940d42d1e7f6362bec38171ea3"
            + "edf433541db4e4ad969f00000000494830450221008b9d1dc26ba6a9cb"
            + "62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be022040529b"
            + "194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed"
            + "01eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9"
            + "b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9"
            + "148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d0000"
            + "00001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac00"
            + "0247304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447"
            + "a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f"
            + "51928d43c212a8caed02de67eebee0121025476c2e83188368da1ff3e2"
            + "92e7acafcdb3566bb0ad253f62fc70f07aeee635711000000"
        )
    }

    @Test
    func solanaMainnetCompatibleTransferMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // Solana/TWAnySignerTests.cpp `SignTransfer`.
        let privateKey = try #require(Base58.decodeNoCheck(
            string: "A7psj2GW7ZMdY4E5hJq14KMeYg7HFjULSsWSrTXZLvYr"
        ))
        let output: SolanaSigningOutput = AnySigner.sign(
            input: SolanaSigningInput.with {
                $0.privateKey = privateKey
                $0.recentBlockhash = "11111111111111111111111111111111"
                $0.transferTransaction = .with {
                    $0.recipient =
                        "EN2sCsJ1WDV8UFqsiTXHcUPUxQ4juE71eCknHYYMifkd"
                    $0.value = 42
                }
            },
            coin: .solana
        )

        #expect(output.error == .ok)
        #expect(output.encoded ==
            "3p2kzZ1DvquqC6LApPuxpTg5CCDVPqJFokGSnGhnBHrta4uq7S2EyehV"
            + "1XNUVXp51D69GxGzQZUjikfDzbWBG2aFtG3gHT1QfLzyFKHM4HQtMQMN"
            + "Xqay1NAeiiYZjNhx9UvMX4uAQZ4Q6rx6m2AYfQ7aoMUrejq298q1wBFd"
            + "tS9XVB5QTiStnzC7zs97FUEK2T4XapjF1519EyFBViTfHpGpnf5bfizD"
            + "zsW9kYUtRDW1UC2LgHr7npgq5W9TBmHf9hSmRgM9XXucjXLqubNWE7H"
            + "UMhbKjuBqkirRM"
        )
        #expect(output.unsignedTx ==
            "87PYsiS4MUU1UqXrsDoCBmD5FcKsXhwEBD8hc4zbq78yePu7bLENmbnm"
            + "jmVbsj4VvaxnZhy4bERndPFzjSRH5WpwKwMLSCKvn9eSDmPESNcdkqne"
            + "2UdMfWiFoq8ZeQBnF9h98dP8GM9kfzWPjvLmhjwuwA1E2k5WCtfii7LK"
            + "Q34v6AtmFQGZqgdKiNqygP7ZKusHWGT8ZkTZ"
        )
    }

    @Test
    func nearMainnetTransferMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // NEAR/TWAnySignerTests.cpp `SignTransfer`.
        let privateKey = try #require(Data(hexString:
            "8737b99bf16fba78e1e753e23ba00c4b"
            + "5423ac9c45d9b9caae9a519434786568"
        ))
        let blockHash = try #require(Data(hexString:
            "0fa473fd26901df296be6adc4cc4df34"
            + "d040efa2435224b6986910e630c2fef6"
        ))
        let deposit = Data(
            [UInt8(1)] + Array(repeating: UInt8(0), count: 15)
        )
        let output: NEARSigningOutput = AnySigner.sign(
            input: NEARSigningInput.with {
                $0.signerID = "test.near"
                $0.nonce = 1
                $0.receiverID = "whatever.near"
                $0.privateKey = privateKey
                $0.blockHash = blockHash
                $0.actions = [
                    NEARAction.with {
                        $0.transfer = .with {
                            $0.deposit = deposit
                        }
                    }
                ]
            },
            coin: .near
        )

        #expect(output.error == .ok)
        #expect(output.signedTransaction.hexString ==
            "09000000746573742e6e65617200917b3d268d4b58f7fec1b150bd68"
            + "d69be3ee5d4cc39855e341538465bb77860d01000000000000000d00"
            + "000077686174657665722e6e6561720fa473fd26901df296be6adc4cc4"
            + "df34d040efa2435224b6986910e630c2fef601000000030100000000"
            + "000000000000000000000000969a83332186ee9755e4839325525806"
            + "e189a3d2d2bb4b4760e94443e97e1c4f22deeef0059a8e9713100eda"
            + "6e19144da7e8a0ef7e539b20708ba1d8d021bd01"
        )
        #expect(output.hash.hexString ==
            "eea6e680f3ea51a7f667e9a801d0bfad"
            + "f66e03d41ed54975b3c6006351461b32"
        )
    }

    @Test
    func xrpMainnetPaymentMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // XRP/TWAnySignerTests.cpp `SignXrpPaymentMain`.
        let privateKey = try #require(Data(hexString:
            "acf1bbf6264e699da0cc65d17ac03fcc"
            + "a6ded1522d19529df7762db46097ff9f"
        ))
        let output: RippleSigningOutput = AnySigner.sign(
            input: RippleSigningInput.with {
                $0.opPayment = .with {
                    $0.amount = 1_000_000
                    $0.destination = "rNLpgsBTCwiaZAnHe2ZViAN1GcXZtYW6rg"
                }
                $0.fee = 10
                $0.sequence = 75_674_534
                $0.lastLedgerSequence = 75_674_797
                $0.account = "rGV1v1xw23PHcRn4Km4tF8R2mfh6yTZkcP"
                $0.privateKey = privateKey
            },
            coin: .xrp
        )

        #expect(output.error == .ok)
        #expect(output.encoded.hexString ==
            "1200002200000000240482b3a6201b0482b4ad6140000000000f4240"
            + "68400000000000000a7321027efc5f15071d2ae5e73ee09a0c17456c"
            + "5d9170a41d67e3297c554829199be80b74473045022100e1c746c3ae"
            + "ebc8278c627ee4c2ce5cae97e3856292c7fe5388f803920230a37b02"
            + "207d2eccb76cd35dd379d6b24c2cabd786e62d34a564cf083e863176"
            + "109c5b6bb48114aa000c09c692ef1f82787e51e22833149941ea2083"
            + "149232ef60695add51f0f84534cc4084e4fdfc698e"
        )
    }

    @Test
    func tronRawJSONTransferMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // swift/Tests/Blockchains/TronTests.swift
        // `testSignRawJsonTransferContract`.
        let privateKey = try #require(Data(hexString:
            "2d8f68944bdbfbc0769542fba8fc2d2a"
            + "3de67393334471624364c7006da2aa54"
        ))
        let rawJSON =
            "{\"raw_data\":{\"contract\":[{\"parameter\":{" +
            "\"type_url\":\"type.googleapis.com/protocol.TransferContract\"," +
            "\"value\":{\"amount\":2000000,\"owner_address\":" +
            "\"415cd0fb0ab3ce40f3051414c604b27756e69e43db\"," +
            "\"to_address\":\"41521ea197907927725ef36d70f25f850d1659c7c7\"}" +
            "},\"type\":\"TransferContract\"}],\"expiration\":1539331479000," +
            "\"ref_block_bytes\":\"7b3b\",\"ref_block_hash\":" +
            "\"b21ace8d6ac20e7e\",\"timestamp\":1539295479000}," +
            "\"raw_data_hex\":\"0a027b3b2208b21ace8d6ac20e7e40d8abb9bae62c" +
            "5a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f" +
            "746f636f6c2e5472616e73666572436f6e747261637412320a15415cd0fb0a" +
            "b3ce40f3051414c604b27756e69e43db121541521ea197907927725ef36d70" +
            "f25f850d1659c7c71880897a70d889a4a9e62c\",\"txID\":" +
            "\"dc6f6d9325ee44ab3c00528472be16e1572ab076aa161ccd12515029869d0451\"}"
        let output: TronSigningOutput = AnySigner.sign(
            input: TronSigningInput.with {
                $0.rawJson = rawJSON
                $0.privateKey = privateKey
            },
            coin: .tron
        )

        #expect(output.error == .ok)
        #expect(output.id.hexString ==
            "dc6f6d9325ee44ab3c00528472be16e1572ab076aa161ccd12515029869d0451"
        )
        #expect(output.signature.hexString ==
            "ede769f6df28aefe6a846be169958c155e23e7e5c9621d2e8dce1719b4d952b"
            + "63e8a8bf9f00e41204ac1bf69b1a663dacdf764367e48e4a5afcd6b055a747"
            + "fb200"
        )
    }

    @Test
    func bitcoinCashMainnetTransferMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // BitcoinCash/TWBitcoinCashTests.cpp `SignTransaction`.
        let privateKey = try #require(Data(hexString:
            "7fdafb9db5bc501f2096e7d13d331dc7"
            + "a75d9594af3d251313ba8b6200f4e384"
        ))
        let utxo = BitcoinUnspentTransaction.with {
            $0.outPoint = .with {
                $0.hash = Data(hexString:
                    "e28c2b955293159898e34c6840d99bf4"
                    + "d390e2ee1c6f606939f18ee1e2000d05"
                )!
                $0.index = 2
                $0.sequence = UInt32.max
            }
            $0.script = Data(hexString:
                "76a914aff1e0789e5fe316b729577665aa0a04d5b0f8c788ac"
            )!
            $0.amount = 5_151
        }
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: BitcoinSigningInput.with {
                $0.hashType = BitcoinScript.hashTypeForCoin(
                    coinType: .bitcoinCash
                )
                $0.amount = 600
                $0.byteFee = 1
                $0.toAddress = "1Bp9U1ogV3A14FMvKbRJms7ctyso4Z4Tcx"
                $0.changeAddress = "1FQc5LdgGHMHEN9nwkjmz6tWkxhPpxBvBU"
                $0.privateKey = [privateKey]
                $0.utxo = [utxo]
                $0.coinType = CoinType.bitcoinCash.rawValue
            },
            coin: .bitcoinCash
        )

        #expect(output.error == .ok)
        #expect(output.encoded.hexString ==
            "0100000001e28c2b955293159898e34c6840d99bf4d390e2ee1c6f606939f18e"
            + "e1e2000d05020000006b483045022100b70d158b43cbcded60e6977e93f9a849"
            + "66bc0cec6f2dfd1463d1223a90563f0d02207548d081069de570a494d0967ba3"
            + "88ff02641d91cadb060587ead95a98d4e3534121038eab72ec78e639d02758e78"
            + "60cdec018b49498c307791f785aa3019622f4ea5bffffffff0258020000000000"
            + "001976a914769bdff96a02f9135a1d19b749db6a78fe07dc9088ace510000000"
            + "0000001976a9149e089b6889e032d46e3b915a3392edfd616fb1c488ac000000"
            + "00"
        )
        #expect(output.transactionID ==
            "96ee20002b34e468f9d3c5ee54f6a8ddaa61c118889c4f35395c2cd93ba5bbb4"
        )
    }

    @Test
    func litecoinMainnetSegwitTransferMatchesTrustWalletCore473() throws {
        // Trust Wallet Core 4.7.3:
        // Bitcoin/TWBitcoinSigningTests.cpp `Sign_LitecoinReal_a85f`.
        let ownAddress =
            "ltc1qt36tu30tgk35tyzsve6jjq3dnhu2rm8l8v5q00"
        let privateKeyData = try #require(Data(hexString:
            "b820f41f96c8b7442f3260acd23b3897"
            + "e1450b8c7c6580136a3c2d3a14e34674"
        ))
        let privateKey = try #require(PrivateKey(data: privateKeyData))
        let publicKey = privateKey.getPublicKeySecp256k1(compressed: true)
        let keyHash = publicKey.bitcoinKeyHash
        let lockScript = BitcoinScript.lockScriptForAddress(
            address: ownAddress,
            coin: .litecoin
        )
        let utxo = BitcoinUnspentTransaction.with {
            $0.outPoint = .with {
                $0.hash = Data(hexString:
                    "b5fd8e818ad98a3f4570383954c1c415"
                    + "13797ec6f9f0ab44a801941818cd5170"
                )!
                $0.index = 9
                $0.sequence = UInt32.max - 1
            }
            $0.script = lockScript.data
            $0.amount = 3_900_000
        }
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: BitcoinSigningInput.with {
                $0.hashType = BitcoinScript.hashTypeForCoin(
                    coinType: .litecoin
                )
                $0.amount = 3_899_774
                $0.useMaxAmount = true
                $0.byteFee = 1
                $0.toAddress =
                    "ltc1q0dvup9kzplv6yulzgzzxkge8d35axkq4n45hum"
                $0.changeAddress = ownAddress
                $0.privateKey = [privateKeyData]
                $0.utxo = [utxo]
                $0.coinType = CoinType.litecoin.rawValue
                $0.scripts = [
                    keyHash.hexString: BitcoinScript
                        .buildPayToPublicKeyHash(hash: keyHash).data
                ]
                $0.plan = .with {
                    $0.availableAmount = 3_900_000
                    $0.amount = 3_899_774
                    $0.fee = 226
                    $0.change = 0
                    $0.utxos = [utxo]
                }
            },
            coin: .litecoin
        )

        #expect(output.error == .ok)
        #expect(output.encoded.hexString ==
            "01000000000101b5fd8e818ad98a3f4570383954c1c41513797ec6f9f0ab44a8"
            + "01941818cd51700900000000feffffff017e813b00000000001600147b59c096c2"
            + "0fd9a273e240846b23276c69d3581502473044022029153096af176f9cca0ba9"
            + "b827e947689a8bb8d11dda570c880f9108bc590b3002202410c78b666722ade1"
            + "ef4547ad85a128ddcbd4695c40f942457bea3d043b9bb30121036739829f2cfec"
            + "79cfe6aaf1c22ecb7d4867dfd8ab4deb7121b36a00ab646caed00000000"
        )
        #expect(output.transactionID ==
            "a85fd6a9a7f2f54cacb57e83dfd408e51c0a5fc82885e3fa06be8692962bc407"
        )
    }

    @Test
    func dogecoinMainnetP2PKHTransferIsDeterministic() throws {
        let privateKeyData = try #require(Data(hexString:
            "7fdafb9db5bc501f2096e7d13d331dc7"
            + "a75d9594af3d251313ba8b6200f4e384"
        ))
        let recipientKeyData = try #require(Data(hexString:
            "608dcb1742bb3fb7aec002074e3420e4f"
            + "ab7d00cced79ccdac53ed5b27138151"
        ))
        let privateKey = try #require(PrivateKey(data: privateKeyData))
        let recipientKey = try #require(PrivateKey(data: recipientKeyData))
        let source = CoinType.dogecoin.deriveAddress(privateKey: privateKey)
        let recipient = CoinType.dogecoin.deriveAddress(
            privateKey: recipientKey
        )
        let lockScript = BitcoinScript.lockScriptForAddress(
            address: source,
            coin: .dogecoin
        )
        let utxo = BitcoinUnspentTransaction.with {
            $0.outPoint = .with {
                $0.hash = Data(repeating: 0x11, count: 32)
                $0.index = 7
                $0.sequence = UInt32.max
            }
            $0.script = lockScript.data
            $0.amount = 100_000_000
        }
        let output: BitcoinSigningOutput = AnySigner.sign(
            input: BitcoinSigningInput.with {
                $0.hashType = BitcoinScript.hashTypeForCoin(
                    coinType: .dogecoin
                )
                $0.amount = 25_000_000
                $0.byteFee = 1
                $0.toAddress = recipient
                $0.changeAddress = source
                $0.privateKey = [privateKeyData]
                $0.utxo = [utxo]
                $0.coinType = CoinType.dogecoin.rawValue
                $0.plan = .with {
                    $0.availableAmount = 100_000_000
                    $0.amount = 25_000_000
                    $0.fee = 226
                    $0.change = 74_999_774
                    $0.utxos = [utxo]
                }
            },
            coin: .dogecoin
        )

        #expect(output.error == .ok, "\(output.errorMessage)")
        #expect(source == "DMBQYj5RC3mLs9awCrqVBB8c8BQfiz6PkC")
        #expect(recipient == "D5M7rqbG9dhuPquvC6MKsM2LDMZuVidY7M")
        #expect(
            output.encoded.hexString
                == "01000000011111111111111111111111111111111111111111111111111111"
                + "111111111111070000006b4830450221009aba63055f4a09ed78fef877c5ca"
                + "b16305daea438f37f33cf7b8f3efab833a1a022018cd3dd9e506c1f39b6e"
                + "0fd9b94cd04fc4727d25890e14972f6474df5c85f8e70121038eab72ec78e"
                + "639d02758e7860cdec018b49498c307791f785aa3019622f4ea5bffffffff"
                + "0240787d01000000001976a914024617fd81c91817912263b2449d1c06a601"
                + "6fa888acde677804000000001976a914aff1e0789e5fe316b729577665aa0a"
                + "04d5b0f8c788ac00000000"
        )
        #expect(
            output.transactionID
                == "19d16ec373ec28cd44f9835c36a4633f92c0d6f5b3b9b3d5a22395f167a5e6dd"
        )
    }

    @Test
    func everyConfiguredEVMMainnetEmbedsItsExactChainID() throws {
        let expected = [
            "eth": 1,
            "bsc": 56,
            "arbitrum": 42_161,
            "base": 8_453,
            "polygon": 137,
            "optimism": 10,
            "avalanche": 43_114,
            "gnosis": 100,
            "linea": 59_144,
            "scroll": 534_352,
            "taiko": 167_000,
            "telos": 40,
            "xlayer": 196,
            "arc": 5_042
        ]
        let configured = Dictionary(
            uniqueKeysWithValues: ReceiveNetworkCatalog.all
                .filter { $0.chainID > 0 }
                .map { ($0.id, $0.chainID) }
        )
        #expect(configured == expected)

        let privateKey = try #require(Data(hexString:
            "608dcb1742bb3fb7aec002074e3420e4f"
            + "ab7d00cced79ccdac53ed5b27138151"
        ))
        var signedEnvelopes = Set<Data>()
        for (networkID, chainID) in expected {
            let output: EthereumSigningOutput = AnySigner.sign(
                input: EthereumSigningInput.with {
                    $0.chainID = Self.unsignedBigEndian(chainID)
                    $0.nonce = Data([1])
                    $0.txMode = .enveloped
                    $0.gasLimit = Data([0x52, 0x08])
                    $0.maxInclusionFeePerGas = Data([1])
                    $0.maxFeePerGas = Data([2])
                    $0.toAddress =
                        "0x5322b34c88ed0691971bf52a7047448f0f4efc84"
                    $0.privateKey = privateKey
                    $0.transaction.transfer = .with {
                        $0.amount = Data([1])
                    }
                },
                coin: .ethereum
            )
            #expect(output.error == .ok, "\(networkID): \(output.errorMessage)")
            #expect(
                Self.eip1559ChainID(output.encoded)
                    == Self.unsignedBigEndian(chainID),
                "\(networkID)"
            )
            signedEnvelopes.insert(output.encoded)
        }
        #expect(signedEnvelopes.count == expected.count)
    }

    @Test
    func invalidCustomDerivationPathIsRejected() throws {
        let wallet = try #require(BIP39Mnemonic.hdWallet(
            mnemonic: "abandon abandon abandon abandon abandon abandon "
                + "abandon abandon abandon abandon abandon about"
        ))

        #expect(wallet.getKey(
            coin: .ethereum,
            derivationPath: "not-a-derivation-path"
        ) == nil)
    }

    private static func unsignedBigEndian(_ value: Int) -> Data {
        var remaining = UInt64(value)
        var bytes: [UInt8] = []
        repeat {
            bytes.append(UInt8(remaining & 0xff))
            remaining >>= 8
        } while remaining > 0
        return Data(bytes.reversed())
    }

    private static func eip1559ChainID(_ encoded: Data) -> Data? {
        guard encoded.first == 2, encoded.count > 2 else { return nil }
        var index = 1
        guard skipRLPListPrefix(encoded, index: &index) else { return nil }
        return readRLPData(encoded, index: &index)
    }

    private static func skipRLPListPrefix(
        _ data: Data,
        index: inout Int
    ) -> Bool {
        guard index < data.count else { return false }
        let prefix = data[index]
        if (0xc0...0xf7).contains(prefix) {
            index += 1
            return true
        }
        guard prefix >= 0xf8 else { return false }
        let lengthByteCount = Int(prefix - 0xf7)
        guard index + lengthByteCount < data.count else { return false }
        index += 1 + lengthByteCount
        return true
    }

    private static func readRLPData(
        _ data: Data,
        index: inout Int
    ) -> Data? {
        guard index < data.count else { return nil }
        let prefix = data[index]
        if prefix <= 0x7f {
            index += 1
            return Data([prefix])
        }
        guard prefix <= 0xb7 else { return nil }
        let length = Int(prefix - 0x80)
        let start = index + 1
        let end = start + length
        guard end <= data.count else { return nil }
        index = end
        return data.subdata(in: start..<end)
    }
}
