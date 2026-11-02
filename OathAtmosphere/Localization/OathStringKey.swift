import Foundation

/// Stable English localization keys shared by SwiftUI, UIKit, and system prompts.
enum OathStringKey: String, CaseIterable, Sendable {
    case appIconSignalBlue = "app_icon.signal_blue"
    case appIconObsidian = "app_icon.obsidian"
    case appIconPorcelain = "app_icon.porcelain"
    case appIconVerdant = "app_icon.verdant"
    case appIconUltraviolet = "app_icon.ultraviolet"
    case appIconElectricLime = "app_icon.electric_lime"
    case appIconEmber = "app_icon.ember"
    case appIconTitanium = "app_icon.titanium"
    case appIconGlacier = "app_icon.glacier"
    case appIconChampagne = "app_icon.champagne"
    case historySwap
    case historyBridge
    case multisigEVMSetupNeeded, multisigEVMFundingNeeded
    case multisigEVMKeyDetail, multisigEVMSetup, multisigEVMSetupDetail, multisigEVMReady, multisigEVMReadyDetail, multisigEVMActivate, multisigEVMFeeDetail, multisigEVMPending, multisigEVMHomeDetail
    case multisigSolanaStorage, multisigSolanaTransferFeeDetail, multisigSolanaFundingNeeded
    case multisigSolanaKeyDetail, multisigSolanaSetup, multisigSolanaSetupDetail, multisigSolanaReady, multisigSolanaReadyDetail, multisigSolanaActivate, multisigSolanaFeeDetail, multisigSolanaPending, multisigSolanaHomeDetail
    case multisigTronKeyDetail, multisigTronSetup, multisigTronSetupDetail, multisigTronReady, multisigTronReadyDetail, multisigTronActivate, multisigTronFeeDetail, multisigTronPending, multisigTronHomeDetail
    case multisigXrplTokenEnabled, multisigXrplReserve, multisigXrplTokenAdd, multisigXrplTokenDetail, multisigXrplTokenType, multisigXrplIssued, multisigXrplMptID, multisigXrplCurrency, multisigXrplIssuer, multisigXrplLimit, multisigXrplTokenReview, multisigXrplTokenReviewAction, multisigXrplTokenInvalid
    case multisigTonKeyDetail
    case multisigThorchainKeyDetail
    case multisigNearKeyDetail
    case multisigNearMinimumFunding
    case multisigNearActivate
    case multisigNearReady
    case multisigNearSetup
    case multisigNearReadyDetail
    case multisigNearSetupDetail
    case multisigNearFeeDetail
    case multisigNearPending
    case multisigSuiKeyDetail
    case multisigAptosKeyDetail
    case multisigStellarKeyDetail, multisigStellarSetup, multisigStellarSetupDetail, multisigStellarReady, multisigStellarReadyDetail, multisigStellarActivate, multisigStellarFeeDetail, multisigStellarPending, multisigStellarHomeDetail, multisigStellarReserve, multisigStellarTokenAdd, multisigStellarTokenDetail, multisigStellarCurrency, multisigStellarIssuer, multisigStellarTokenReview, multisigStellarTokenReviewAction, multisigStellarTokenInvalid
    case multisigXrplKeyDetail, multisigXrplSetup, multisigXrplSetupDetail, multisigXrplReady, multisigXrplReadyDetail, multisigXrplActivate, multisigXrplFeeDetail, multisigXrplPending, multisigXrplHomeDetail
    case multisigTotalKeys, multisigRequired, multisigKeyNumber, multisigKeySource
    case multisigCreateKey, multisigKeyReady, multisigDuplicateKey, multisigWIFDetail, multisigLitecoinWIFDetail, multisigDogecoinWIFDetail, multisigBitcoinCashWIFDetail
    case multisigOptionalPassphrase, multisigLocalKeys, multisigRecovery, multisigRecoveryDetail
    case multisigNoticeTitle, multisigNoticeDetail, multisigGotIt, multisigFundingWarning
    case stablecoinRestrictionTitle, stablecoinRestrictionDetail, stablecoinRestrictionWarning
    case legacyUpgradeTitle, legacyUpgradeAuthenticate, legacyUpgradeProgress, legacyUpgradeFailure, legacyUpgradeUnsupported, legacyUpgradeBiometrics, legacyUpgradeBiometricsDetail, legacyUpgradeEnableBiometrics, legacyUpgradePasscodeOnly
    case wcSolanaFeePayer, wcSolanaSimulation, wcSolanaSignOnly, wcSolanaPrograms, wcSolanaBatch, wcSolanaTestnet, wcSolanaPartial
    case wcSolanaDurableNonce, wcSolanaNonceAccount
    case wcApprovalPending, wcApprovalPendingDetail, wcApprovalConfirmed, wcApprovalConfirmedDetail, wcSwapProgress, wcSwapProgressDetail, wcSwapRefunded, wcSwapObserved, wcSwapRefundPending, wcDepositStage, wcSwapStage, wcDeliveryStage, wcStageConfirmed, wcStageWaiting, wcOutboundTransaction, wcRefundTransaction, wcSwapObservationSource, wcSwapProgressUnavailable
    case wcCrossSwap, wcEstimatedReceive, wcReceiveNetwork, wcOutboundFee, wcLiquidityFee, wcAffiliateFee, wcAffiliate, wcSwapFeesDetail, wcCrossSwapDetail, wcNoMinimum
    case wcConfirmSwap, wcSwapMinimumPayout, wcSwapPriceImpact, wcSwapSlippage, wcSwapIncludedFees, wcSwapEstimatedTime, wcSwapGasFee, wcSwapExchange, wcSwapNetworkAddress, wcSwapEstimateDetail
    case wcBatchRequest, wcNetworkRequest, wcBatchUnavailable, wcNetworkUnavailable, wcBatchUnavailableDetail, wcNetworkUnavailableDetail, wcSwapDetails
    case wcAmbiguousApproval, wcApprovalRawValue, wcEditableApprovalDetail, wcTokenBalance, wcLimitFailed
    case wcSwitchNetwork
    case wcCurrentNetwork
    case wcRequestedNetwork
    case wcSwitchNetworkDetail
    case wcCosmosAccountNumber
    case wcCosmosSequence
    case wcTimeoutHeight
    case wcCosmosDocumentDetail
    case wcRequestDeclined
    case wcRequestDeclinedDetail
    case wcNetworkChanged
    case wcReviewTransaction
    case wcReviewApproval
    case wcReviewSwap
    case wcReviewNFT
    case historyTokenApproval, historyApprovalRemoval
    case wcContractCall
    case wcCallWarning
    case wcApprovalCallDetail
    case wcOperatorDetail
    case wcCallValue
    case wcDecodedUnavailable, wcOptionalStep, wcWrapNative, wcUnwrapNative, wcRouterBalance
    case wcTransactionData
    case wcTransactionDataDetail
    case wcMaximumFee
    case wcFeeDetails
    case wcFeeDetail
    case wcGasLimit
    case wcGasPrice
    case wcPriorityFee
    case wcRollupFee
    case wcCallMethod
    case wcRawAmount
    case wcTokenID
    case wcTokenIn
    case wcTokenOut
    case wcMinimumOut
    case wcPoolFee
    case wcPriceLimit
    case wcSwapCallDetail
    case wcSubmitTransaction
    case wcTransactionPending
    case wcTransactionPendingDetail
    case wcTransactionConfirmed
    case wcTransactionConfirmedDetail
    case wcTransactionFailed
    case wcTransactionFailedDetail
    case wcTransactionCancelled, wcTransactionCancelledDetail
    case wcTransactionReplaced, wcTransactionReplacedDetail
    case wcNeedGas
    case wcNeedGasDetail
    case wcSimulationFailed
    case wcSimulationFailedDetail
    case wcSendingDetail
    case wcConfirmedLimit
    case wcUnlimitedDetail

    case wcPreparingDetail
    case wcSignInTitle
    case wcSignInDetail
    case wcSignInResourcesDetail
    case wcFullMessage
    case wcAboutSignature
    case wcSignedPermissionDetail
    case wcSignatureSent
    case wcSignatureSentDetail
    case wcTransactionSigned
    case wcTransactionSignedDetail
    case wcExpiredTitle
    case wcExpiredDetail
    case wcInvalidTitle
    case wcInvalidDetail
    case wcInterruptedTitle
    case wcInterruptedDetail
    case wcChangedTitle
    case wcChangedDetail
    case wcQuoteUpdated, wcTransactionBusy
    case wcSignData
    case wcApproveSignature

    case wcNonce = "wc.nonce"
    case wcConnectTo
    case wcChooseWallet
    case wcChooseWalletDetail
    case wcNetworks
    case wcChooseNetworksDetail
    case wcNetworkAccessDetail
    case wcConnectionSummary
    case wcReviewPermissions
    case wcWebsiteDetails
    case wcDomainMatches
    case wcDomainUnknown
    case wcUnsupportedTitle
    case wcUnsupportedDetail
    case wcPublicInformation
    case wcRequestsYouApprove
    case wcPrivateInformation
    case wcPrivateInformationDetail
    case wcMethodsDetail
    case wcRequestOrigin
    case wcDomainCheck
    case wcDomainCheckDetail

    case wcTypedReviewTitle
    case wcTypedReviewDetail
    case wcPermitReviewTitle
    case wcPermitReviewDetail
    case wcSigningDomain
    case wcVerifyingContract
    case wcSignedType
    case wcNoSigningFee
    case wcNoChainBinding
    case wcAllSignedFields
    case wcSignedFieldsDetail
    case wcTypedWarning
    case wcPermitDeadlineDetail
    case wcPermit2AllowanceDetail
    case wcPermit2TransferDetail
    case wcTokenContract
    case wcSpender
    case wcReviewAsset, wcReviewSpender
    case wcApproveAmountOnNetwork
    case wcAtomicLimit
    case wcSignatureDeadline
    case wcAllowanceExpiry

    case accountNearStorageFunds = "send.account_help.near_storage_funds"
    case accountCostReserve = "send.account_cost.reserve"
    case accountCostCreation = "send.account_cost.creation"
    case accountCostTokenDeposit = "send.account_cost.token_deposit"
    case accountCostIncluded = "send.account_cost.included"
    case accountCostPaymentExplanation = "send.account_cost.payment_explanation"
    case accountCostExtraExplanation = "send.account_cost.extra_explanation"
    case accountCostXrpDetail = "send.account_cost.xrp_detail"
    case accountCostStellarDetail = "send.account_cost.stellar_detail"
    case accountCostSolanaDetail = "send.account_cost.solana_detail"
    case accountCostTronDetail = "send.account_cost.tron_detail"
    case accountCostSolanaTokenDetail = "send.account_cost.solana_token_detail"
    case accountCostNearDetail = "send.account_cost.near_detail"
    case accountHelpTitle = "send.account_help.title"
    case accountLearnMore = "send.account_help.learn_more"
    case accountMinimumPayment = "send.account_help.minimum_payment"
    case accountRequiredFees = "send.account_help.required_fees"
    case accountMinimumMessage = "send.account_help.minimum_message"
    case accountActivationIncluded = "send.account_help.activation_included"
    case accountTokenActivation = "send.account_help.token_activation"
    case accountReserveShort = "send.account_help.reserve_short"
    case accountReserveInfo = "send.account_help.reserve_info"
    case accountTrustlineShort = "send.account_help.trustline_short"
    case accountTronActivationShort = "send.account_help.tron_activation_short"
    case accountTronActivationInfo = "send.account_help.tron_activation_info"
    case accountTronTokenInfo = "send.account_help.tron_token_info"
    case accountTronResourcesShort = "send.account_help.tron_resources_short"
    case accountTronResourcesInfo = "send.account_help.tron_resources_info"
    case accountTronSenderShort = "send.account_help.tron_sender_short"
    case accountNearMissingShort = "send.account_help.near_missing_short"
    case accountNearStorageShort = "send.account_help.near_storage_short"
    case accountNearStorageInfo = "send.account_help.near_storage_info"
    case accountSolanaRentShort = "send.account_help.solana_rent_short"
    case accountSolanaRentInfo = "send.account_help.solana_rent_info"
    case accountSolanaStorageShort = "send.account_help.solana_storage_short"
    case accountXrpActivationDetail = "send.account_help.xrp_activation_detail"
    case accountStellarActivationDetail = "send.account_help.stellar_activation_detail"
    case accountSolanaActivationDetail = "send.account_help.solana_activation_detail"
    case accountXrpTokenDetail = "send.account_help.xrp_token_detail"
    case accountStellarTokenDetail = "send.account_help.stellar_token_detail"
    case accountStellarTrustlineDetail = "send.account_help.stellar_trustline_detail"
    case accountXrpReserveDetail = "send.account_help.xrp_reserve_detail"
    case accountStellarReserveDetail = "send.account_help.stellar_reserve_detail"
    case accountTronActivationDetail = "send.account_help.tron_activation_detail"
    case accountTronTokenDetail = "send.account_help.tron_token_detail"
    case accountTronResourcesDetail = "send.account_help.tron_resources_detail"
    case accountTronSenderDetail = "send.account_help.tron_sender_detail"
    case accountNearMissingDetail = "send.account_help.near_missing_detail"
    case accountNearTokenDetail = "send.account_help.near_token_detail"
    case accountNearStorageDetail = "send.account_help.near_storage_detail"
    case accountNearStorageUnsupportedDetail = "send.account_help.near_storage_unsupported_detail"
    case accountSolanaRentDetail = "send.account_help.solana_rent_detail"
    case accountSolanaStorageDetail = "send.account_help.solana_storage_detail"
    case permissionNonce = "permissions.nonce"
    case permissionNonceDetail = "permissions.nonce_detail"
    case permissionNonceAdvanced = "permissions.nonce_advanced"
    case permissionAtomic = "permissions.atomic"
    case sendMessageDoesNotFit = "send.message_does_not_fit"
    case sendOptions = "send.options"
    case sendRBF = "send.rbf"
    case sendRBFHint = "send.rbf_hint"
    case sendRBFBitcoinHint = "send.rbf_bitcoin_hint"
    case sendPublicMessage = "send.public_message"
    case sendOnChainMessage = "send.on_chain_message"
    case sendMessageBytes = "send.message_bytes"
    case sendMessageHint = "send.message_hint"
    case sendMessageBitcoinHint = "send.message_bitcoin_hint"
    case sendMessageTooLarge = "send.message_too_large"
    case sendOptionOn = "send.option_on"
    case sendOptionOff = "send.option_off"

    case tronAccountUnsupported = "send.tron.account_unsupported"
    case tronSimulationFailed = "send.tron.simulation_failed"
    case tronFeeTooHigh = "send.tron.fee_too_high"
    case tronSendFailed = "send.tron.failed"
    case tronInsufficientFunds = "send.tron.insufficient_funds"
    case tronFeeNotice = "send.tron.fee_notice"
    case stellarReserveRequired = "send.stellar_reserve_required"
    case stellarMemoUnsupported = "send.stellar_memo_unsupported"
    case stellarMemoRequired = "send.stellar_memo_required"
    case stellarRecipientUnfunded = "send.stellar_recipient_unfunded"
    case stellarAccountUnsupported = "send.stellar_account_unsupported"
    case stellarPaymentRestricted = "send.stellar_payment_restricted"
    case stellarSendFailed = "send.stellar_send_failed"
    case stellarRestoreRequired = "send.stellar_restore_required"
    case stellarFeeTooHigh = "send.stellar_fee_too_high"
    case stellarReserveNotice = "send.stellar_reserve_notice"
    case stellarFeeMaximum = "send.stellar_fee_maximum"
    case stellarMemoType = "send.stellar_memo_type"
    case stellarMemoText = "send.stellar_memo_text"
    case stellarMemoID = "send.stellar_memo_i_d"
    case stellarMemoHash = "send.stellar_memo_hash"
    case stellarMemoReturn = "send.stellar_memo_return"

    case xrplCloseTitle = "send.xrpl_close_title"
    case xrplCloseReview = "send.xrpl_close_review"
    case xrplCloseConfirm = "send.xrpl_close_confirm"
    case xrplCloseExplanation = "send.xrpl_close_explanation"
    case xrplCloseUnavailable = "send.xrpl_close_unavailable"
    case xrplCloseTooSoon = "send.xrpl_close_too_soon"
    case xrplCloseObligations = "send.xrpl_close_obligations"
    case xrplCloseRecipient = "send.xrpl_close_recipient"
    case xrplCloseWarning = "send.xrpl_close_warning"
    case xrplReserveRequired = "send.xrpl_reserve_required"
    case xrplTagRequired = "send.xrpl_tag_required"
    case xrplRecipientUnfunded = "send.xrpl_recipient_unfunded"
    case xrplAccountUnsupported = "send.xrpl_account_unsupported"
    case xrplPaymentRestricted = "send.xrpl_payment_restricted"
    case xrplSendFailed = "send.xrpl_failed"
    case xrplReserveNotice = "send.xrpl_reserve_notice"
    case xrplTokenFee = "send.xrpl_token_fee"
    case suiGasRequired = "send.sui_gas_required"
    case suiSendFailed = "send.sui_failed"
    case suiGasReserved = "send.sui_gas_reserved"
    case sendRemaining = "send.remaining"
    case sendFeeAdjusted = "send.fee_adjusted"
    case sendPreparing = "send.preparing"
    case sendRefreshNeeded = "send.refresh_needed"
    case sendAdjustAmount = "send.adjust_amount"
    case sendRefreshQuote = "send.refresh_quote"
    case sendAuthorize = "send.authorize"
    case sendSending = "send.sending"
    case sendLoadingFee = "send.loading_fee"
    case sendSubmitted = "send.submitted"
    case sendSent = "send.sent"
    case sendChecking = "send.checking"
    case sendSubmittedDetail = "send.submitted_detail"
    case sendSubmittedRecipient = "send.submitted_recipient"
    case sendConfirmedRecipient = "send.confirmed_recipient"
    case sendContactSupport = "send.contact_support"
    case sendCheckingDetail = "send.checking_detail"
    case sendBitcoinFeeHint = "send.bitcoin_fee_hint"

    case sendRecipient = "send.recipient"
    case sendAmount = "send.amount"
    case sendAssetTo = "send.asset_to"
    case sendChangeAddress = "send.change_address"
    case sendAmountReviewHint = "send.amount_review_hint"
    case sendDecimalSeparator = "send.decimal_separator"
    case sendReview = "send.review"
    case sendConfirmAndSend = "send.confirm_and_send"
    case sendChooseAsset = "send.choose_asset"
    case sendWhosItFor = "send.whos_it_for"
    case sendAssetOnNetwork = "send.asset_on_network"
    case sendNetworkHint = "send.network_hint"
    case sendAddressInvalid = "send.address_invalid"
    case sendSelfTransferNetwork = "send.self_transfer_network"
    case sendSelfTransferWallet = "send.self_transfer_wallet"
    case sendDestinationTag = "send.destination_tag"
    case sendMemo = "send.memo"
    case sendDestinationTagLabel = "send.destination_tag_label"
    case sendMemoHint = "send.memo_hint"
    case sendMemoInvalid = "send.memo_invalid"
    case sendNoContacts = "send.no_contacts"
    case sendNoContactsTitle = "send.no_contacts_title"
    case sendLoadFailed = "send.load_failed"
    case sendNoAssets = "send.no_assets"
    case sendBalanceUnknown = "send.balance_unknown"
    case sendAvailable = "send.available"
    case sendMax = "send.max"
    case sendSwitchUnit = "send.switch_unit"
    case sendFeeNotIncluded = "send.fee_not_included"
    case sendInsufficient = "send.insufficient"
    case sendTooPrecise = "send.too_precise"
    case sendAmountInvalid = "send.amount_invalid"
    case sendYoureSending = "send.youre_sending"
    case sendEditAmount = "send.edit_amount"
    case sendShowAddress = "send.show_address"
    case sendTotal = "send.total"
    case sendFeeUnavailable = "send.fee_unavailable"
    case sendReviewChanged = "send.review_changed"
    case sendNotAvailable = "send.not_available"
    case sendConfirmAmount = "send.confirm_amount"

    case historyFilters = "history.filter.filters"
    case historyFilterDetail = "history.filter.detail"
    case historyNetworks = "history.filter.networks"
    case historyAny = "history.filter.any"
    case historySelectedCount = "history.filter.selected_count"
    case historyType = "history.filter.type"
    case historyDate = "history.filter.date"
    case historyAnytime = "history.filter.anytime"
    case historyToday = "history.filter.today"
    case historyWeek = "history.filter.week"
    case historyMonth = "history.filter.month"
    case historyCustomDates = "history.filter.custom_dates"
    case historyStartDate = "history.filter.start_date"
    case historyEndDate = "history.filter.end_date"
    case historyAmount = "history.filter.amount"
    case historyMinimum = "history.filter.minimum"
    case historyMaximum = "history.filter.maximum"
    case historyNoLimit = "history.filter.no_limit"
    case historyAmountDetail = "history.filter.amount_detail"
    case historyInvalidRange = "history.filter.invalid_range"
    case historyResetFilters = "history.filter.reset"
    case historyNoResults = "history.filter.no_results"
    case historyNoResultsDetail = "history.filter.no_results_detail"
    case historyEmptyDetail = "history.empty_detail"
    case historyActiveCount = "history.filter.active_count"
    case historyRemoveFilter = "history.filter.remove_filter"
    case walletTab = "home.wallet_tab"
    case historyTab = "home.history_tab"
    case searchTitle = "common.search"
    case searchTransactions = "transaction.search"
    case backup = "settings.backup"
    case backupAllWallets = "backup.all_wallets"
    case backupAllDetail = "backup.all_detail"
    case backupAllProgress = "backup.all_progress"
    case backupAllEmpty = "backup.all_empty"
    case backupNotYet = "backup.not_yet"
    case requestFeature = "settings.request_feature"
    case submitBug = "settings.submit_bug"
    case contactUs = "settings.contact_us"
    case contactMailUnavailable = "settings.mail_unavailable"
    case copyEmailAddress = "settings.copy_email"
    case aboutOath = "settings.about"
    case appVersionBuild = "about.version_build"
    case appCheckUpdates = "about.check_updates"
    case appCheckingUpdates = "about.checking_updates"
    case appUpToDate = "about.up_to_date"
    case appUpdateStore = "about.update_store"
    case appUpdateUnavailable = "about.update_unavailable"
    case articles = "settings.articles"
    case privacyPolicy = "settings.privacy_policy"
    case termsOfService = "settings.terms_of_service"
    case helpCenter = "settings.help_center"
    case permissions = "settings.permissions"
    case comingSoon = "settings.coming_soon"
    case solanaPreparing = "solana.preparing"
    case solanaReceivePath = "solana.receive_path"
    case solanaReceivePathDetail = "solana.receive_path_detail"
    case solanaOriginalAddress = "solana.original_address"
    case privateKeyFormatDogecoin, privateKeyFormatLitecoin, privateKeyFormatBitcoinCash

    case bitcoinAddressType = "bitcoin.address_type"
    case bitcoinNativeSegwit = "bitcoin.address_type.native_segwit"
    case bitcoinLegacy = "bitcoin.address_type.legacy"
    case bitcoinPreparing = "bitcoin.preparing"
    case bitcoinSingleKey = "bitcoin.single_key"
    case bitcoinAllTypes = "bitcoin.all_types"
    case bitcoinScopedKey = "bitcoin.scoped_key"
    case bitcoinReceiveTracking = "bitcoin.receive_tracking"
    case bitcoinKeyFormat = "bitcoin.key_format"
    case assetInformation = "asset.information"
    case assetInformationDetail = "asset.information_detail"
    case assetPrice = "asset.price"
    case assetPriceLabel = "asset.price_label"
    case assetPriceUnavailable = "asset.price_unavailable"
    case assetMarketLoading = "asset.market_loading"
    case assetChart24h = "asset.chart_24h"
    case assetChartCurrency = "asset.chart_currency"
    case assetChartUnavailable = "asset.chart_unavailable"
    case assetSavedPrice = "asset.saved_price"
    case assetSavedChart = "asset.saved_chart"
    case assetTime = "asset.time"
    case assetActivity = "asset.activity"
    case assetViewAllActivity = "asset.view_all_activity"
    case assetActivityEmpty = "asset.activity_empty"
    case assetActivityEmptyDetail = "asset.activity_empty_detail"
    case assetCanceled = "asset.canceled"
    case assetSelfTransfer = "asset.self_transfer"
    case transactionConfirmations = "transaction.confirmations"
    case transactionInputs = "transaction.inputs"
    case transactionOutputs = "transaction.outputs"
    case transactionMultipleSenders = "transaction.multiple_senders"
    case transactionMultipleRecipients = "transaction.multiple_recipients"
    case transactionExpanded = "transaction.expanded"
    case transactionCollapsed = "transaction.collapsed"
    case transactionStatus = "transaction.status"
    case transactionAssetTitle = "transaction.asset_title"
    case transactionNetworkFee = "transaction.network_fee"
    case transactionFrom = "transaction.from"
    case transactionTo = "transaction.to"
    case transactionReplacement = "transaction.replacement"
    case transactionCurrentValue = "transaction.current_value"
    case transactionViewExplorer = "transaction.view_explorer"
    case transactionShare = "transaction.share"
    case transactionShareImage = "transaction.share_image"
    case transactionShareLink = "transaction.share_link"
    case transactionShareFailed = "transaction.share_failed"
    case assetReceived = "asset.received"
    case assetSent = "asset.sent"
    case assetMoreActivity = "asset.more_activity"
    case assetSymbol = "asset.symbol"
    case assetType = "asset.type"
    case assetFilterTitle = "asset.filter.title"
    case assetFilterSort = "asset.filter.sort"
    case assetFilterRecommended = "asset.filter.recommended"
    case assetFilterHighestValue = "asset.filter.highest_value"
    case assetFilterLowestValue = "asset.filter.lowest_value"
    case assetFilterNameAscending = "asset.filter.name_ascending"
    case assetFilterNameDescending = "asset.filter.name_descending"
    case assetFilterMostActive = "asset.filter.most_active"
    case assetFilterAllAssets = "asset.filter.all_assets"
    case assetFilterCoins = "asset.filter.coins"
    case assetFilterTokens = "asset.filter.tokens"
    case assetFilterAllNetworks = "asset.filter.all_networks"
    case assetFilterSearchNetworks = "asset.filter.search_networks"
    case assetFilterHideZero = "asset.filter.hide_zero"
    case assetFilterGroupTokens = "asset.filter.group_tokens"
    case assetFilterHideUnverified = "asset.filter.hide_unverified"
    case assetFilterSaveFailed = "asset.filter.save_failed"
    case assetFilterWithActivity = "asset.filter.with_activity"
    case assetFilterBalanceDetail = "asset.filter.balance_detail"
    case assetFilterValueRange = "asset.filter.value_range"
    case assetFilterValueDetail = "asset.filter.value_detail"
    case assetFilterValueLabel = "asset.filter.value_label"
    case assetFilterMatches = "asset.filter.matches"
    case assetFilterShowing = "asset.filter.showing"
    case assetFilterNoResults = "asset.filter.no_results"
    case assetFilterNoResultsDetail = "asset.filter.no_results_detail"
    case assetFilterNoAssets = "asset.filter.no_assets"
    case assetFilterNoAssetsDetail = "asset.filter.no_assets_detail"
    case assetNativeCoin = "asset.native_coin"
    case assetToken = "asset.token"
    case assetAbout = "asset.about"
    case assetWebsite = "asset.website"
    case assetMarketCap = "asset.market_cap"
    case assetTotalSupply = "asset.total_supply"
    case assetCirculatingSupply = "asset.circulating_supply"
    case assetSavedInformation = "asset.saved_information"
    case assetInformationUnavailable = "asset.information_unavailable"
    case assetTransaction = "asset.transaction"
    case assetTransactionID = "asset.transaction_id"
    case assetCopyTransaction = "asset.copy_transaction"
    case assetConfirmed = "asset.confirmed"
    case assetPending = "asset.pending"
    case assetFailed = "asset.failed"
    case assetReplaced = "asset.replaced"
    case assetReorged = "asset.reorged"
    case back = "common.back"
    case close = "common.close"
    case done = "common.done"
    case apply = "common.apply"
    case continueAction = "common.continue"
    case customizeWallet = "wallet.customize"
    case walletColor = "wallet.animation_color"
    case customWalletColor = "wallet.choose_color"
    case walletDefaultColor = "wallet.default_color"
    case walletColorValue = "wallet.color_value"
    case walletCustomizeFailed = "wallet.customize_failed"
    case save = "common.save"
    case add = "common.add"
    case cancel = "common.cancel"
    case delete = "common.delete"
    case tryAgain = "common.try_again"
    case addToken = "token.add"
    case tokenDetails = "token.details"
    case tokenSearchFound = "token.search_found"
    case tokenSearchReview = "token.search_review"
    case tokenSearching = "token.searching"
    case tokenNetworkUnavailable = "token.network_unavailable"
    case tokenInvalidAddress = "token.invalid_address"
    case tokenNotFound = "token.not_found"
    case tokenSearchIncomplete = "token.search_incomplete"
    case tokenNetwork = "token.network"
    case tokenStandard = "token.standard"
    case tokenBankStandard = "token.standard.bank"
    case tokenDecimals = "token.decimals"
    case tokenContract = "token.contract"
    case tokenVerifyDetail = "token.verify_detail"
    case tokenCopyAddress = "token.copy_address"
    case tokenAddFailed = "token.add_failed"
    case notNow = "common.not_now"
    case showPassword = "common.show_password"
    case hidePassword = "common.hide_password"
    case showPrivateKey = "common.show_private_key"
    case hidePrivateKey = "common.hide_private_key"
    case language = "settings.language"
    case preferences = "preferences.title"
    case currency = "preferences.currency"
    case appIcon = "preferences.app_icon"
    case appIconOriginal = "preferences.icon_original"
    case appIconMonochrome = "preferences.icon_monochrome"
    case appIconUnavailable = "preferences.icon_unavailable"
    case appIconChangeFailed = "preferences.icon_change_failed"
    case preferencesSaveFailed = "preferences.save_failed"
    case searchCurrencies = "preferences.search_currencies"
    case mostUsedCurrencies = "preferences.most_used_currencies"
    case allCurrencies = "preferences.all_currencies"
    case loadingExchangeRates = "preferences.loading_rates"
    case exchangeRatesUnavailable = "preferences.rates_unavailable"
    case exchangeRatesCached = "preferences.rates_cached"
    case exchangeRatesDate = "preferences.rates_date"
    case exchangeRatesDetail = "preferences.rates_detail"
    case exchangeRatesSource = "preferences.rates_source"
    case contacts = "contacts.title"
    case addContact = "contacts.add"
    case editContact = "contacts.edit"
    case contactDetails = "contacts.details"
    case contactName = "contacts.name"
    case contactAddress = "contacts.address"
    case contactAddressLabel = "contacts.address_label"
    case contactChooseNetwork = "contacts.choose_network"
    case addContactAddress = "contacts.add_address"
    case removeContactAddress = "contacts.remove_address"
    case contactEditAddress = "contacts.edit_address"
    case contactDeleteAllAddresses = "contacts.delete_all_addresses"
    case contactScanAddress = "contacts.scan_address"
    case contactCameraFailed = "contacts.camera_failed"
    case contactCameraUnavailable = "contacts.camera_unavailable"
    case contactAddressesEmpty = "contacts.addresses_empty"
    case contactRemoveAddressDetail = "contacts.remove_address_detail"
    case contactAddressLimit = "contacts.address_limit"
    case contactAddressDetail = "contacts.address_detail"
    case contactAddressCount = "contacts.address_count"
    case searchContacts = "contacts.search"
    case contactsEmpty = "contacts.empty"
    case contactsEmptyDetail = "contacts.empty_detail"
    case contactsNoResults = "contacts.no_results"
    case contactsLoadFailed = "contacts.load_failed"
    case contactsSaveFailed = "contacts.save_failed"
    case contactNotFound = "contacts.not_found"
    case contactNameInvalid = "contacts.invalid_name"
    case contactAddressInvalid = "contacts.invalid_address"
    case contactLabelInvalid = "contacts.invalid_label"
    case contactAddressRequired = "contacts.address_required"
    case contactDuplicateAddress = "contacts.duplicate_address"
    case contactChanged = "contacts.changed"
    case deleteContact = "contacts.delete"
    case deleteContactDetail = "contacts.delete_detail"
    case hapticFeedback = "settings.hapticFeedback"
    case appearance = "settings.appearance"
    case appearanceLight = "settings.appearance_light"
    case appearanceDark = "settings.appearance_dark"
    case appearanceSystem = "settings.appearance_system"
    case systemLanguage = "settings.system_language"
    case searchLanguages = "settings.search_languages"
    case noLanguageResultsDetail = "settings.no_language_results_detail"
    case createWallet = "onboarding.create_wallet"
    case createMultisignatureWallet = "onboarding.create_multisignature_wallet"
    case importWallet = "onboarding.import_wallet"
    case moreOptions = "onboarding.more_options"
    case brandLine = "onboarding.brand_line"
    case headline = "onboarding.headline"
    case consent = "onboarding.consent"
    case send = "feature.send"
    case sendUnavailable = "send.unavailable"
    case receive = "feature.receive"
    case pay = "feature.pay"
    case requestCrypto = "feature.request_crypto"
    case selfCustody = "feature.self_custody"
    case featuresAccessibility = "feature.accessibility"
    case restoreICloud = "restore.icloud_title"
    case restoreDetail = "restore.detail"
    case importPrivateKey = "import.private_key"
    case importDetail = "import.detail"
    case noBackups = "restore.empty_title"
    case noBackupsDetail = "restore.empty_detail"
    case restoreAction = "restore.action"
    case restoreComplete = "restore.complete"
    case restoreBackupNumber = "restore.backup_number"
    case restoreChooseDetail = "restore.choose_detail"
    case restoreSearching = "restore.searching"
    case restoreDownloading = "restore.downloading"
    case restoreDecrypting = "restore.decrypting"
    case restoreSaving = "restore.saving"
    case restorePasswordDetail = "restore.password_detail"
    case restoreWrongPassword = "restore.wrong_password"
    case restoreInvalidBackup = "restore.invalid_backup"
    case restoreConflict = "restore.conflict"
    case restoreMissing = "restore.missing"
    case restoreDownloadFailed = "restore.download_failed"
    case restoreDiscoveryFailed = "restore.discovery_failed"
    case restoreFailed = "restore.failed"
    case backToOptions = "restore.back_to_options"
    case chooseChain = "import.choose_chain"
    case searchChains = "import.search_chains"
    case evmTitle = "import.evm_title"
    case popularNetworks = "import.popular_networks"
    case chains = "import.chains"
    case additionalNetworks = "import.additional_networks"
    case evmAccessibility = "import.evm_accessibility"
    case chainAccessibility = "import.chain_accessibility"
    case noSearchResults = "import.no_results"
    case noSearchResultsDetail = "import.no_results_detail"
    case setPasscode = "passcode.set_title"
    case confirmPasscode = "passcode.confirm_title"
    case setPasscodeDetail = "passcode.set_detail"
    case confirmPasscodeDetail = "passcode.confirm_detail"
    case differentPasscode = "passcode.start_over"
    case passcode = "passcode.accessibility"
    case pinCount = "passcode.digit_count"
    case savingPasscode = "passcode.saving"
    case settingUpBiometrics = "biometrics.setting_up"
    case mismatch = "passcode.mismatch"
    case interrupted = "passcode.interrupted"
    case usePasscode = "passcode.use"
    case passcodeSuccess = "passcode.success_title"
    case passcodeAlreadySet = "passcode.already_set_title"
    case unlockDevice = "passcode.unlock_title"
    case passcodeSaveFailed = "passcode.save_failed_title"
    case biometricsUnavailable = "biometrics.unavailable_title"
    case biometricsName = "biometrics.generic_name"
    case passcodeBiometricsSuccess = "passcode.biometric_success"
    case passcodeSaved = "passcode.saved"
    case passcodeAlreadySetDetail = "passcode.already_set_detail"
    case unlockDeviceDetail = "passcode.unlock_detail"
    case passcodeSaveFailedDetail = "passcode.save_failed_detail"
    case biometricsLocked = "biometrics.locked_out"
    case biometricsStorageFailed = "biometrics.storage_failed"
    case biometricsFailed = "biometrics.failed"
    case retryBiometrics = "biometrics.retry"
    case enableBiometrics = "biometrics.enable_reason"
    case deleteDigit = "keypad.delete"
    case useBiometrics = "keypad.use_biometrics"
    case paste = "common.paste"
    case clear = "common.clear"
    case scan = "common.scan"
    case importAction = "common.import"
    case openSettings = "common.open_settings"
    case addSeedPassword, seedPasswordLabel, seedPasswordConfirm, seedPasswordCreate, seedPasswordRowDetail, seedPasswordDetail, seedPasswordNormalization
    case recoveryFormat, electrumType, electrumTwoFactorDetail, electrumAmbiguous, electrumInvalidPhrase
    case aezeedType, aezeedWrongPassphrase, aezeedUnsupportedVersion, aezeedInvalidPhrase
    case recoveryDetail = "recovery.detail"
    case recoveryPhrase = "recovery.phrase"
    case recoveryWordCount = "recovery.word_count"
    case recoveryWordCounts = "recovery.word_counts"
    case recoveryEmpty = "recovery.empty"
    case recoveryTooLong = "recovery.too_long"
    case recoveryUnknownWord = "recovery.unknown_word"
    case recoveryMixedWords = "recovery.mixed_words"
    case recoveryChecksum = "recovery.checksum"
    case recoveryUnavailable = "recovery.unavailable"
    case recoveryValid = "recovery.valid"
    case recoveryScanTitle = "recovery.scan_title"
    case recoveryScanInvalid = "recovery.scan_invalid"
    case recoveryCameraUnavailable = "recovery.camera_unavailable"
    case recoveryCameraDenied = "recovery.camera_denied"
    case recoveryCameraFailed = "recovery.camera_failed"
    case recoveryScanErrorTitle = "recovery.scan_error_title"
    case myWallet = "home.my_wallet"
    case pullToRefresh = "home.refresh_pull"
    case refreshing = "home.refresh_running"
    case refreshSucceeded = "home.refresh_succeeded"
    case refreshFailed = "home.refresh_failed"
    case wallets = "wallet.wallets"
    case editWallets = "wallets.edit"
    case recentlyDeleted = "wallets.recently_deleted"
    case recentlyDeletedDetail = "wallets.recently_deleted_detail"
    case recentlyDeletedEmpty = "wallets.recently_deleted_empty"
    case selectAllWallets = "wallets.select_all"
    case deselectAllWallets = "wallets.deselect_all"
    case recoverWallets = "wallets.restore"
    case deleteWalletsPermanently = "wallets.delete_permanently"
    case walletDeletionDate = "wallets.deletion_date"
    case walletRemovalAuthentication = "wallets.removal_authentication"
    case walletRemovalFailed = "wallets.removal_failed"
    case removeWallets = "wallets.remove"
    case deleteWallet = "wallets.delete"
    case moveToRecentlyDeleted = "wallets.move_to_deleted"
    case walletRemovalTitle = "wallets.removal_title"
    case walletPermanentRemovalTitle = "wallets.permanent_removal_title"
    case walletRemovalDetail = "wallets.removal_detail"
    case walletPermanentRemovalDetail = "wallets.permanent_removal_detail"
    case addWallet = "wallet.add"
    case switchWallet = "wallet.switch"
    case makeWalletActive = "wallet.make_active"
    case numberedWallet = "wallet.numbered_name"
    case mainWalletName = "wallet.default_name.main"
    case importedWalletName = "wallet.default_name.imported"
    case restoredWalletName = "wallet.default_name.restored"
    case networkWalletName = "wallet.default_name.network"
    case indexedWalletName = "wallet.default_name.indexed"
    case passphraseWalletName = "wallet.default_name.passphrase"
    case currentWallet = "wallet.current"
    case walletDetails = "wallet.settings"
    case walletName = "wallet.name"
    case walletNameHint = "wallet.name_hint"
    case walletRenameFailed = "wallet.rename_failed"
    case cloudBackupSection = "cloud_backup.section"
    case cloudBackupSwitch = "cloud_backup.switch"
    case cloudBackupDetail = "cloud_backup.detail"
    case cloudBackupPasswordTitle = "cloud_backup.password_title"
    case cloudBackupPasswordDetail = "cloud_backup.password_detail"
    case cloudBackupPassword = "cloud_backup.password"
    case cloudBackupConfirmPassword = "cloud_backup.confirm_password"
    case cloudBackupPasswordMismatch = "cloud_backup.password_mismatch"
    case cloudBackupStart = "cloud_backup.start"
    case cloudBackupEncrypting = "cloud_backup.encrypting"
    case cloudBackupUploading = "cloud_backup.uploading"
    case cloudBackupWaiting = "cloud_backup.waiting"
    case cloudBackupComplete = "cloud_backup.complete"
    case cloudBackupUnavailable = "cloud_backup.unavailable"
    case cloudBackupAccountChanged = "cloud_backup.account_changed"
    case cloudBackupQuota = "cloud_backup.quota"
    case cloudBackupFailed = "cloud_backup.failed"
    case cloudBackupMissing = "cloud_backup.missing"
    case walletChangeFailed = "wallet.change_failed"
    case walletChangeFailedDetail = "wallet.change_failed_detail"
    case walletSettings = "home.settings"
    case totalBalance = "home.total_balance"
    case balanceChangeTitle = "home.balance_change.title"
    case balanceChangeToday = "home.balance_change.today"
    case balanceChangePeriodTitle = "home.balance_change.period_title"
    case balanceChangeWeek = "home.balance_change.week"
    case balanceChangeMonth = "home.balance_change.month"
    case balanceChangeSixMonths = "home.balance_change.six_months"
    case balanceChangeYear = "home.balance_change.year"
    case balanceChangeAll = "home.balance_change.all"
    case balanceChangeUnavailable = "home.balance_change.unavailable"
    case hideAsset = "asset.visibility.hide"
    case showAsset = "asset.visibility.show"
    case hiddenAssets = "asset.visibility.hidden"
    case hiddenAssetsEmpty = "asset.visibility.empty"
    case hideBalance = "home.hide_balance"
    case balanceHidden = "home.balance_hidden"
    case networkCount = "home.network_count"
    case assets = "home.assets"
    case searchAssets = "home.search_assets"
    case securedOnDevice = "home.secured_on_device"
    case walletBackup = "wallet.backup"
    case backupReminder = "wallet.backup_reminder"
    case backupReminderDetail = "wallet.backup_reminder_detail"
    case chooseReceiveNetwork = "receive.choose_network"
    case receiveQRCode = "receive.qr_code"
    case receiveNetworkDetail = "receive.network_detail"
    case copyAddress = "receive.copy_address"
    case addressCopied = "receive.address_copied"
    case shareAddress = "receive.share_address"
    case shareQRCode = "receive.share_qr_code"
    case receiveShare = "receive.share"
    case receiveAssetTitle = "receive.asset_title"
    case receiveAccountReserve = "receive.activation.reserve"
    case receiveTronActivation = "receive.activation.tron"
    case receiveNearActivation = "receive.activation.near"
    case receiveTonActivation = "receive.activation.ton"
    case receiveTonDeployment = "receive.activation.ton_deployment"
    case receiveAboutTitle = "receive.about_title"
    case receiveBack = "receive.back_to_receive"
    case receiveExampleAssets = "receive.example_assets"
    case receiveAndMore = "receive.and_more"
    case receiveExamplesHint = "receive.examples_hint"
    case receiveManyAssetsTitle = "receive.many_assets_title"
    case receiveNativeTitle = "receive.native_title"
    case receiveTokenNotice = "receive.token_notice"
    case receiveSelectedTokenNotice = "receive.selected_token_notice"
    case receiveNativeNotice = "receive.native_notice"
    case receiveTrustlineNotice = "receive.trustline_notice"
    case receiveRegistrationNotice = "receive.registration_notice"
    case receiveEVMExplanation = "receive.evm_explanation"
    case receiveSolanaExplanation = "receive.solana_explanation"
    case receiveThorchainExplanation = "receive.thorchain_explanation"
    case receiveTronExplanation = "receive.tron_explanation"
    case receiveJettonExplanation = "receive.jetton_explanation"
    case receiveNearExplanation = "receive.near_explanation"
    case receiveTrustlineExplanation = "receive.trustline_explanation"
    case receiveAptosExplanation = "receive.aptos_explanation"
    case receiveSuiExplanation = "receive.sui_explanation"
    case receiveNativeExplanation = "receive.native_explanation"
    case receiveMatchNetworkTitle = "receive.match_network_title"
    case receiveMatchNetworkDetail = "receive.match_network_detail"
    case receiveExamplesTitle = "receive.examples_title"
    case receiveExamplesDetail = "receive.examples_detail"
    case receiveAfterTransferTitle = "receive.after_transfer_title"
    case receiveManualTracking = "receive.manual_tracking"
    case receiveDeferredTracking = "receive.deferred_tracking"
    case receiveNativeTracking = "receive.native_tracking"
    case receiveExamplesOnNetwork = "receive.examples_on_network"
    case recoverySafety = "wallet.recovery_safety"
    case showRecoveryPhrase = "wallet.show_recovery_phrase"
    case viewRecoveryPhrase = "recovery_view.title"
    case recoveryRowDetail = "recovery_view.row_detail"
    case recoveryWarningTitle = "recovery_view.warning_title"
    case recoveryWarningDetail = "recovery_view.warning_detail"
    case recoveryNeverShare = "recovery_view.never_share"
    case recoveryNeverShareDetail = "recovery_view.never_share_detail"
    case recoveryAvoidScreenshots = "recovery_view.avoid_screenshots"
    case recoveryAvoidScreenshotsDetail = "recovery_view.avoid_screenshots_detail"
    case recoveryStoreSecurely = "recovery_view.store_securely"
    case recoveryStoreSecurelyDetail = "recovery_view.store_securely_detail"
    case recoveryUnderstand = "recovery_view.understand"
    case recoveryAuthenticationReason = "recovery_view.authentication_reason"
    case recoveryKeepSafe = "recovery_view.keep_safe"
    case recoveryViewDetail = "recovery_view.detail"
    case recoveryCopy = "recovery_view.copy"
    case recoveryCopied = "recovery_view.copied"
    case viewPrivateKeys = "private_key_view.title"
    case privateKeyRowDetail = "private_key_view.row_detail"
    case viewPrivateKey = "private_key_view.key_title"
    case privateKeyChooseChain = "private_key_view.choose_chain"
    case privateKeyAuthenticationReason = "private_key_view.authentication_reason"
    case privateKeyWarningTitle = "private_key_view.warning_title"
    case privateKeyWarningDetail = "private_key_view.warning_detail"
    case privateKeyNeverShare = "private_key_view.never_share"
    case privateKeyNeverShareDetail = "private_key_view.never_share_detail"
    case privateKeyAvoidScreenshotsDetail = "private_key_view.avoid_screenshots_detail"
    case privateKeyStoreSecurelyDetail = "private_key_view.store_securely_detail"
    case privateKeyViewDetail = "private_key_view.detail"
    case privateKeyKeepSafe = "private_key_view.keep_safe"
    case privateKeyEVMScopeWarning = "private_key_view.evm_scope_warning"
    case privateKeyFormat = "private_key_view.format"
    case privateKeyAddressesTitle = "private_key_view.addresses_title"
    case privateKeyGeneratedDetail = "private_key_view.generated_detail"
    case privateKeyPath = "private_key_view.path"
    case privateKeyReceiveAddresses = "private_key_view.receive_addresses"
    case privateKeyChangeAddresses = "private_key_view.change_addresses"
    case privateKeyAddressNumber = "private_key_view.address_number"
    case privateKeyLoadMore = "private_key_view.load_more"
    case privateKeyQRCode = "private_key_view.qr_code"
    case privateKeyQRDetail = "private_key_view.qr_detail"
    case privateKeyAccount = "private_key_view.account"
    case confirmBackup = "wallet.confirm_backup"
    case backupSaved = "wallet.backup_saved"
    case lockWallet = "wallet.lock"
    case security = "security.title"
    case securityAuthenticationReason = "security.authentication_reason"
    case changePasscode = "security.change_passcode"
    case verifyCurrentPasscode = "security.verify_passcode"
    case appSwitcherPrivacy = "security.switcher_privacy"
    case appSwitcherPrivacyDetail = "security.switcher_privacy_detail"
    case hideRecentlyDeletedInSwitcher = "security.hide_recently_deleted_switcher"
    case hideRecentlyDeletedInSwitcherDetail = "security.hide_recently_deleted_switcher_detail"
    case requirePasscode = "security.require_passcode"
    case lockImmediately = "security.immediately"
    case lockOneMinute = "security.one_minute"
    case lockFiveMinutes = "security.five_minutes"
    case lockTenMinutes = "security.ten_minutes"
    case lockDelayDetail = "security.delay_detail"
    case securityChangeFailed = "security.change_failed"
    case unlockWallet = "wallet.unlock"
    case unlockPasscodeTitle = "wallet.unlock_passcode_title"
    case enterPasscode = "wallet.enter_passcode"
    case unlockIncorrect = "wallet.incorrect_passcode"
    case unlockWait = "wallet.unlock_wait"
    case unlockReason = "wallet.unlock_reason"
    case biometricUnlockReset = "wallet.biometric_reset"
    case biometricUnlockFailed = "wallet.biometric_failed"
    case walletUnavailable = "wallet.unavailable"
    case privateKeyInput = "private_key_import.input"
    case privateKeyImportDetail = "private_key_import.detail"
    case privateKeyInvalid = "private_key_import.invalid"
    case privateKeyFormatWIF = "private_key_import.format_wif"
    case privateKeyFormatSolana = "private_key_import.format_solana"
    case privateKeyFormatNear = "private_key_import.format_near"
    case privateKeyFormatStellar = "private_key_import.format_stellar"
    case privateKeyFormatSui = "private_key_import.format_sui"
    case privateKeyFormatAptos = "private_key_import.format_aptos"
    case privateKeyFormatXRP = "private_key_import.format_xrp"
    case privateKeyFormatPolkadot = "private_key_import.format_polkadot"
    case receivePolkadotExplanation = "receive.polkadot_explanation"
    case privateKeyFormatHex = "private_key_import.format_hex"
    case resetApp = "reset.title"
    case resetAuthenticationReason = "reset.authentication_reason"
    case resetAuthorizationFailed = "reset.authorization_failed"
    case receiveIndexedTracking = "receive.indexed_tracking"
    case resetWarningTitle = "reset.warning_title"
    case resetWarningDetail = "reset.warning_detail"
    case resetWalletsTitle = "reset.wallets_title"
    case resetWalletsDetail = "reset.wallets_detail"
    case resetDataTitle = "reset.data_title"
    case resetDataDetail = "reset.data_detail"
    case resetKeptTitle = "reset.kept_title"
    case resetKeptDetail = "reset.kept_detail"
    case resetCloudDetail = "reset.cloud_detail"
    case resetConfirm = "reset.confirm"
    case resetProgress = "reset.progress"
    case resetFailed = "reset.failed"
    case addPassphrase = "passphrase.add"
    case walletPassphrase = "passphrase.label"
    case passphraseWallet = "passphrase.wallet"
    case passphraseRowDetail = "passphrase.row_detail"
    case passphraseIntroTitle = "passphrase.intro_title"
    case passphraseIntroSeparate = "passphrase.intro_separate"
    case passphraseIntroExact = "passphrase.intro_exact"
    case passphraseIntroRecovery = "passphrase.intro_recovery"
    case passphraseStorageDetail = "passphrase.storage_detail"
    case passphraseContinue = "passphrase.continue"
    case passphraseEntryDetail = "passphrase.entry_detail"
    case passphraseConfirm = "passphrase.confirm"
    case passphraseCreate = "passphrase.create"
    case passphraseCreating = "passphrase.creating"
    case passphraseMismatch = "passphrase.mismatch"
    case passphraseTooLong = "passphrase.too_long"
    case passphraseInvalid = "passphrase.invalid"
    case passphraseAlreadyExists = "passphrase.already_exists"
    case passphraseOpenExisting = "passphrase.open_existing"
    case passphraseRecoveryDetail = "passphrase.recovery_detail"
    case passphraseCopy = "passphrase.copy"


    case tonAccountUnsupported, tonMetadataChanged, tonFeeTooHigh, tonInsufficientFunds, tonSimulationFailed, tonSendFailed
    case solanaAccountUnsupported, solanaMetadataChanged, solanaFeeTooHigh, solanaInsufficientFunds, solanaSimulationFailed, solanaSendFailed, solanaTokenUnsupported, solanaAccountRent, solanaRecipientReceives
    case arcInsufficientFunds, arcAccountUnsupported, arcMetadataChanged, arcFeeTooHigh, arcSimulationFailed, arcSendFailed, arcFeeMaximum
    case thorchainAccountUnsupported, thorchainMetadataChanged, thorchainFeeTooHigh, thorchainInsufficientFunds, thorchainHalted, thorchainSendFailed
    case sendNativeFeeRequired
    case sendNativeFeeShort = "send.native_fee_short"
    case sendReceiveFeeAsset = "send.receive_fee_asset"
    case aptosAccountUnsupported, aptosMetadataChanged, aptosFeeTooHigh, aptosInsufficientFunds, aptosSimulationFailed, aptosSendFailed
    case nearAccountUnsupported, nearRecipientMissing, nearMetadataChanged, nearStorageUnsupported, nearFeeTooHigh, nearSendFailed, nearInsufficientFunds, nearStorageDeposit, nearFeeNotice
    case scannerReady
    case scannerDetail
    case scannerPhotos
    case scannerFlashlight
    case scannerHelp
    case scannerHelpDetail
    case scannerRecognizing
    case scannerChooseCode
    case scannerChooseCodeDetail
    case scannerCode
    case scannerNoCode
    case scannerNoCodeDetail
    case scannerEmptyPaste
    case scannerEmptyPasteDetail
    case scannerPaused
    case scannerPausedDetail
    case scannerResume
    case scannerPermission
    case scannerPermissionDetail
    case scannerUnavailable
    case scannerUnavailableDetail
    case scannerAddress
    case scannerPayment
    case scannerNetworkChoice
    case scannerNetworkDetail
    case scannerMismatch
    case scannerMismatchDetail
    case scannerAssetMismatchDetail
    case scannerUseAddress
    case scannerRecovery
    case scannerRecoveryDetail
    case scannerWords
    case scannerUsePhrase
    case scannerPrivateKey
    case scannerPrivateKeyDetail
    case scannerUseKey
    case scannerInvalidRecovery
    case scannerInvalidRecoveryDetail
    case scannerInvalid
    case scannerInvalidDetail
    case scannerExpired
    case scannerExpiredDetail
    case scannerScanAgain
    case scannerNotNow
    case scannerPrivateHint
    case scannerNetwork
    case scannerAmount
    case scannerMemo
    case scannerToken
    case scannerAtomicAmount = "scanner.atomic_amount"
    case scannerRequestNote
    case scannerPaymentUnsupported
    case scannerImportWallet
    case scannerContinue
    case walletConnect
    case wcAddConnection
    case wcEmptyDetail
    case wcScanDetail
    case wcOpenWebsite
    case wcConnectionDetails
    case wcStatus
    case wcConnectedSince
    case wcConnectedFor
    case wcExpires
    case wcDateUnknown
    case wcWalletUnavailable
    case wcNetworksAccounts
    case wcNamespace
    case wcMethods
    case wcEvents
    case wcDisconnectPending
    case wcDisconnectDetail
    case wcDisconnectRetryDetail
    case wcDisconnected
    case wcDisconnectedDetail
    case scannerConnect
    case scannerWCDetail
    case scannerWCLoading
    case scannerWCUnavailable
    case scannerWCError
    case wcConnectionInvalidQRTitle
    case wcConnectionInvalidQRDetail
    case wcConnectionExpiredQRTitle
    case wcConnectionExpiredQRDetail
    case wcConnectionUsedQRTitle
    case wcConnectionUsedQRDetail
    case wcConnectionPeerTimeoutTitle
    case wcConnectionPeerTimeoutDetail
    case wcConnectionRelayTimeoutTitle
    case wcConnectionRelayTimeoutDetail
    case wcConnectionOfflineTitle
    case wcConnectionOfflineDetail
    case wcConnectionRelayUnavailableTitle
    case wcConnectionRelayUnavailableDetail
    case wcConnectionConfigurationTitle
    case wcConnectionConfigurationDetail
    case wcConnectionLockedTitle
    case wcConnectionLockedDetail
    case wcConnectionConnectionLimitTitle
    case wcConnectionConnectionLimitDetail
    case wcConnectionAccountsTitle
    case wcConnectionAccountsDetail
    case wcConnectionUnsupportedNetworksTitle
    case wcConnectionUnsupportedNetworksDetail
    case wcConnectionUnsupportedMethodsTitle
    case wcConnectionUnsupportedMethodsDetail
    case wcConnectionUnsupportedEventsTitle
    case wcConnectionUnsupportedEventsDetail
    case wcConnectionProposalUnavailableTitle
    case wcConnectionProposalUnavailableDetail
    case wcConnectionUnknownTitle
    case wcConnectionUnknownDetail
    case scannerWCUnverified
    case scannerWCUnverifiedDetail
    case scannerWCAcknowledge
    case scannerWCBlocked
    case scannerWCBlockedDetail
    case scannerWCConnected
    case scannerWCConnectedDetail
    case scannerWCDisconnect
    case scannerWCReject
    case scannerWCAccount
    case scannerWCPermissions
    case scannerWCAccountsPermission
    case scannerWCMessagePermission
    case scannerWCRequired
    case scannerWCOptional
    case scannerWCSign
    case scannerWCSignDetail
    case scannerWCSessions
    case scannerWCNoSessions
    case scannerWCSignatureFailed
    case wcSignTransaction
    case wcTransactionPermission
    case wcTransactionDetail
    case wcProtocolDeposit
    case wcProtocolDepositDetail
    case wcProtocolFee
    case wcTransactionMemo
    case permissionTokens = "permissions.permissionTokens"
    case permissionCollectibles = "permissions.permissionCollectibles"
    case permissionConnections = "permissions.permissionConnections"
    case permissionControl = "permissions.permissionControl"
    case permissionHistory = "permissions.permissionHistory"
    case permissionCoverage = "permissions.permissionCoverage"
    case permissionHelp = "permissions.permissionHelp"
    case permissionIntro = "permissions.permissionIntro"
    case permissionCheck = "permissions.permissionCheck"
    case permissionContract = "permissions.permissionContract"
    case permissionSpender = "permissions.permissionSpender"
    case permissionType = "permissions.permissionType"
    case permissionTokenID = "permissions.permissionTokenID"
    case permissionAccess = "permissions.permissionAccess"
    case permissionRemove = "permissions.permissionRemove"
    case permissionReview = "permissions.permissionReview"
    case permissionAfter = "permissions.permissionAfter"
    case permissionNone = "permissions.permissionNone"
    case permissionDelegationDetail = "permissions.delegation_detail"
    case permissionControlDetail = "permissions.control_detail"
    case permissionExpired = "permissions.expired"
    case permissionNoTransfer = "permissions.permissionNoTransfer"
    case permissionUnknown = "permissions.permissionUnknown"
    case permissionLimited = "permissions.permissionLimited"
    case permissionUnlimited = "permissions.permissionUnlimited"
    case permissionAllItems = "permissions.permissionAllItems"
    case permissionOneItem = "permissions.permissionOneItem"
    case permissionDelegate = "permissions.permissionDelegate"
    case permissionPermanent = "permissions.permissionPermanent"
    case permissionUnsupported = "permissions.permissionUnsupported"
    case permissionPermanentDetail = "permissions.permissionPermanentDetail"
    case permissionPermitDetail = "permissions.permissionPermitDetail"
    case permissionPermitBlock = "permissions.permissionPermitBlock"
    case permissionEmpty = "permissions.permissionEmpty"
    case permissionEmptyDetail = "permissions.permissionEmptyDetail"
    case permissionSearch = "permissions.permissionSearch"
    case permissionNoResults = "permissions.permissionNoResults"
    case permissionChecked = "permissions.permissionChecked"
    case permissionPartial = "permissions.permissionPartial"
    case permissionUnavailable = "permissions.permissionUnavailable"
    case permissionNotIndexed = "permissions.permissionNotIndexed"
    case permissionScan = "permissions.permissionScan"
    case permissionCoverageDetail = "permissions.permissionCoverageDetail"
    case permissionSubmitted = "permissions.permissionSubmitted"
    case permissionPending = "permissions.permissionPending"
    case permissionPendingDetail = "permissions.permissionPendingDetail"
    case permissionRemoved = "permissions.permissionRemoved"
    case permissionVerified = "permissions.permissionVerified"
    case permissionStillActive = "permissions.permissionStillActive"
    case permissionFailed = "permissions.permissionFailed"
    case permissionError = "permissions.permissionError"
    case permissionChanged = "permissions.permissionChanged"
    case permissionAlready = "permissions.permissionAlready"
    case permissionInsufficient = "permissions.permissionInsufficient"
    case permissionReadOnly = "permissions.permissionReadOnly"
    case permissionHistoryEmpty = "permissions.permissionHistoryEmpty"
    case permissionHistoryDetail = "permissions.permissionHistoryDetail"
    case permissionKnownSignatures = "permissions.permissionKnownSignatures"
    case permissionSignatureHelp = "permissions.permissionSignatureHelp"
    case permissionDeviceHelp = "permissions.permissionDeviceHelp"
    case permissionOpenSettings = "permissions.permissionOpenSettings"
    case permissionSelect = "permissions.permissionSelect"
    case permissionRevokeAll, permissionBatchDetail, permissionBatchPaused
    case permissionSelection = "permissions.permissionSelection"
    case permissionSequential = "permissions.permissionSequential"
    case permissionFeeUnknown = "permissions.permissionFeeUnknown"
    case permissionInvalid = "permissions.permissionInvalid"
    case wcContractAddress
    case wcWalletDescription
}
