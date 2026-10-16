// Isolated TESTNET fixture only; not bundled in the wallet.
module oath_test::test_tokens {
    use std::signer;
    use std::option;
    use std::string;
    use aptos_framework::managed_coin;
    use aptos_framework::coin;
    use aptos_framework::object;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    struct TestCoin {}
    fun init_module(owner: &signer) {
        managed_coin::initialize<TestCoin>(owner, b"Oath Test Coin", b"OTC", 6, true);
        coin::register<TestCoin>(owner);
        managed_coin::mint<TestCoin>(owner, signer::address_of(owner), 1000000000);
        let constructor = object::create_named_object(owner, b"OATH_TEST_FA");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor, option::none(), string::utf8(b"Oath Test FA"),
            string::utf8(b"OTFA"), 6, string::utf8(b""), string::utf8(b"")
        );
        let mint = fungible_asset::generate_mint_ref(&constructor);
        primary_fungible_store::mint(&mint, signer::address_of(owner), 1000000000);
    }
    #[view]
    public fun metadata(): address {
        object::create_object_address(&@oath_test, b"OATH_TEST_FA")
    }
}
