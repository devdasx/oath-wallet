#!/usr/bin/env node

const tonAddress =
  "0:66fbe3c5c03bf5c82792f904c9f8bf28894a6aa3d213d41c20569b654aadedb3";
const suiEndpoint = "https://graphql.mainnet.sui.io/graphql";
const xrpEndpoint = "https://s1.ripple.com:51234/";
const nearReadEndpoint = "https://free.rpc.fastnear.com";
const nearSubmissionEndpoint =
  "https://aperture-notifications.devdas98x.workers.dev" +
  "/v1/provider/ankr/near/jsonrpc";
const aptosEndpoint = "https://fullnode.mainnet.aptoslabs.com/v1";
const stellarEndpoint = "https://rpc.ankr.com/http/stellar_horizon";
const stellarUSDCIssuer =
  "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function request(url, options = {}, attempt = 0) {
  const response = await fetch(url, {
    ...options,
    headers: {
      accept: "application/json",
      ...(options.headers ?? {}),
    },
    signal: AbortSignal.timeout(15_000),
  });
  if (response.status === 429 && attempt < 5) {
    await new Promise((resolve) => {
      setTimeout(resolve, 1_500 * (attempt + 1));
    });
    return request(url, options, attempt + 1);
  }
  const text = await response.text();
  let object;
  try {
    object = JSON.parse(text);
  } catch {
    throw new Error(`${url}: non-JSON response (${response.status})`);
  }
  return { status: response.status, object };
}

async function postJSON(url, body) {
  return request(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function verifyTON() {
  const started = Date.now();
  const encodedAddress = encodeURIComponent(tonAddress);
  const [account, seqno, invalidBroadcast] = await Promise.all([
    request(`https://tonapi.io/v2/accounts/${encodedAddress}`),
    request(`https://tonapi.io/v2/wallet/${encodedAddress}/seqno`),
    postJSON("https://toncenter.com/api/v2/sendBocReturnHash", {
      boc: "AA==",
    }),
  ]);
  assert(account.status === 200, `TON account HTTP ${account.status}`);
  assert(
    account.object?.address === tonAddress &&
      account.object?.status === "active" &&
      account.object?.interfaces?.includes("wallet_v4r2"),
    "TON Wallet V4R2 account identity is invalid",
  );
  assert(
    seqno.status === 200 && Number.isSafeInteger(seqno.object?.seqno),
    "TON seqno is invalid",
  );
  assert(
    invalidBroadcast.object?.ok === false &&
      /bag.of.cells|boc/i.test(invalidBroadcast.object?.error ?? ""),
    "TON invalid BOC was not rejected",
  );
  return `ton: wallet_v4r2=verified seqno=${seqno.object.seqno} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function suiGraphQL(query, variables = {}) {
  const { status, object } = await postJSON(suiEndpoint, {
    query,
    variables,
  });
  assert(status === 200, `Sui GraphQL HTTP ${status}`);
  return object;
}

async function verifySui() {
  const started = Date.now();
  const [identity, invalidBroadcast] = await Promise.all([
    suiGraphQL("query { chainIdentifier epoch { referenceGasPrice } }"),
    suiGraphQL(
      "mutation Execute($transaction: Base64!, $signature: Base64!) { " +
        "executeTransaction(transactionDataBcs: $transaction, " +
        "signatures: [$signature]) { effects { digest status " +
        "executionError { message } } } }",
      { transaction: "AA==", signature: "AA==" },
    ),
  ]);
  assert(
    typeof identity?.data?.chainIdentifier === "string" &&
      identity.data.chainIdentifier.length > 20,
    "Sui chain identifier is invalid",
  );
  assert(
    /^\d+$/.test(identity?.data?.epoch?.referenceGasPrice ?? "") &&
      BigInt(identity.data.epoch.referenceGasPrice) > 0n,
    "Sui reference gas price is invalid",
  );
  const error = invalidBroadcast?.errors?.[0];
  assert(
    invalidBroadcast?.data === null &&
      error?.extensions?.code === "BAD_USER_INPUT" &&
      /TransactionData/i.test(error?.message ?? ""),
    "Sui invalid signed transaction was not rejected by the live mutation",
  );
  assert(
    !/Cannot query field.*errors/i.test(error?.message ?? ""),
    "Sui execute mutation still requests the removed errors field",
  );
  return `sui: chain=${identity.data.chainIdentifier} reference_gas_price=${identity.data.epoch.referenceGasPrice} execute_schema=verified invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function xrpRPC(method, parameters = {}) {
  const { status, object } = await postJSON(xrpEndpoint, {
    method,
    params: [parameters],
  });
  assert(status === 200, `XRP ${method}: HTTP ${status}`);
  return object?.result;
}

async function verifyXRP() {
  const started = Date.now();
  const rootAccount = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";
  const [server, account, invalidBroadcast] = await Promise.all([
    xrpRPC("server_info"),
    xrpRPC("account_info", {
      account: rootAccount,
      ledger_index: "validated",
      strict: true,
    }),
    xrpRPC("submit", { tx_blob: "00", fail_hard: true }),
  ]);
  assert(
    server?.status === "success" &&
      server?.info?.network_id === 0 &&
      Number.isSafeInteger(server?.info?.validated_ledger?.seq),
    "XRP mainnet server identity is invalid",
  );
  assert(
    account?.status === "success" &&
      account?.validated === true &&
      account?.account_data?.Account === rootAccount &&
      /^\d+$/.test(account?.account_data?.Balance ?? ""),
    "XRP account state is invalid",
  );
  assert(
    invalidBroadcast?.status === "error" &&
      invalidBroadcast?.error === "invalidTransaction",
    "XRP invalid transaction was not rejected",
  );
  return `xrp: network_id=0 ledger=${server.info.validated_ledger.seq} account_state=verified invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function nearRPC(method, params, endpoint = nearReadEndpoint) {
  const { status, object } = await postJSON(endpoint, {
    jsonrpc: "2.0",
    id: "aperture-live-send-verification",
    method,
    params,
  });
  return { status, object };
}

async function verifyNEAR() {
  const started = Date.now();
  const [statusResult, accountResult, protocolResult, invalidBroadcast] =
    await Promise.all([
      nearRPC("status", []),
      nearRPC("query", {
        request_type: "view_account",
        finality: "final",
        account_id: "wrap.near",
      }),
      nearRPC("EXPERIMENTAL_protocol_config", { finality: "final" }),
      nearRPC(
        "send_tx",
        {
          signed_tx_base64: "AA==",
          wait_until: "EXECUTED",
        },
        nearSubmissionEndpoint,
      ),
    ]);
  assert(
    statusResult.status === 200 &&
      statusResult.object?.result?.chain_id === "mainnet" &&
      statusResult.object?.result?.sync_info?.syncing === false,
    "NEAR mainnet status is invalid",
  );
  assert(
    accountResult.status === 200 &&
      /^\d+$/.test(accountResult.object?.result?.amount ?? "") &&
      /^\d+$/.test(String(accountResult.object?.result?.storage_usage ?? "")),
    "NEAR account state is invalid",
  );
  assert(
    protocolResult.status === 200 &&
      protocolResult.object?.result?.chain_id === "mainnet" &&
      /^\d+$/.test(
        protocolResult.object?.result?.runtime_config?.storage_amount_per_byte ??
          "",
      ),
    "NEAR protocol storage configuration is invalid",
  );
  assert(
    invalidBroadcast.status === 400 &&
      invalidBroadcast.object?.error?.code === -32700 &&
      /parse error/i.test(invalidBroadcast.object?.error?.message ?? ""),
    "NEAR production submission route did not reach mainnet validation",
  );
  return `near: chain=mainnet storage_usage=${accountResult.object.result.storage_usage} protocol=${protocolResult.object.result.protocol_version} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function verifyAptos() {
  const started = Date.now();
  const [ledger, gas, invalidBroadcast] = await Promise.all([
    request(aptosEndpoint),
    request(`${aptosEndpoint}/estimate_gas_price`),
    request(`${aptosEndpoint}/transactions`, {
      method: "POST",
      headers: {
        "content-type": "application/x.aptos.signed_transaction+bcs",
      },
      body: Buffer.from([0]),
    }),
  ]);
  assert(
    ledger.status === 200 &&
      ledger.object?.chain_id === 1 &&
      /^\d+$/.test(ledger.object?.ledger_version ?? ""),
    "Aptos mainnet ledger identity is invalid",
  );
  assert(
    gas.status === 200 &&
      Number.isSafeInteger(gas.object?.gas_estimate) &&
      gas.object.gas_estimate > 0,
    "Aptos gas estimate is invalid",
  );
  assert(
    invalidBroadcast.status === 400 &&
      invalidBroadcast.object?.error_code === "invalid_input" &&
      /SignedTransaction/i.test(invalidBroadcast.object?.message ?? ""),
    "Aptos invalid BCS transaction was not rejected",
  );
  return `aptos: chain=1 ledger=${ledger.object.ledger_version} gas_price=${gas.object.gas_estimate} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function verifyStellar() {
  const started = Date.now();
  const invalidForm = new URLSearchParams({ tx: "AAAA" }).toString();
  const [root, fees, account, invalidBroadcast] = await Promise.all([
    request(stellarEndpoint),
    request(`${stellarEndpoint}/fee_stats`),
    request(`${stellarEndpoint}/accounts/${stellarUSDCIssuer}`),
    request(`${stellarEndpoint}/transactions`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: invalidForm,
    }),
  ]);
  assert(
    root.status === 200 &&
      root.object?.network_passphrase ===
        "Public Global Stellar Network ; September 2015",
    "Stellar network passphrase is invalid",
  );
  assert(
    fees.status === 200 &&
      /^\d+$/.test(fees.object?.fee_charged?.mode ?? "") &&
      BigInt(fees.object.fee_charged.mode) >= 100n,
    "Stellar fee stats are invalid",
  );
  assert(
    account.status === 200 &&
      account.object?.account_id === stellarUSDCIssuer &&
      /^\d+$/.test(account.object?.sequence ?? ""),
    "Stellar account state is invalid",
  );
  assert(
    invalidBroadcast.status === 400 &&
      invalidBroadcast.object?.status === 400 &&
      /transaction_malformed/.test(invalidBroadcast.object?.type ?? ""),
    "Stellar malformed XDR was not rejected",
  );
  return `stellar: passphrase=verified sequence=${account.object.sequence} fee_mode=${fees.object.fee_charged.mode} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

const results = await Promise.all([
  verifyTON(),
  verifySui(),
  verifyXRP(),
  verifyNEAR(),
  verifyAptos(),
  verifyStellar(),
]);
for (const result of results) process.stdout.write(`${result}\n`);
