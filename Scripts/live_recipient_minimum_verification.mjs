#!/usr/bin/env node

const stellarEndpoints = [
  "https://rpc.ankr.com/http/stellar_horizon",
  "https://horizon.stellar.lobstr.co",
];
const stellarRecipient =
  "GBBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEEQSCIJBEFZSP";
const xrpEndpoint = "https://s1.ripple.com:51234";
const xrpRecipient = "rnBFvgZphmN39GWzUJeUitaP22Fr9be75H";
const solanaEndpoints = [
  "https://solana-rpc.publicnode.com",
  "https://api.mainnet-beta.solana.com",
];
const solanaRecipient = "5TeWSsjg2gbxCyWVniXeCmwM7UtHTCK7svzJr5xYJzHf";
const nearEndpoints = [
  "https://aperture-notifications.devdas98x.workers.dev" +
    "/v1/provider/ankr/near/jsonrpc",
  "https://free.rpc.fastnear.com",
];
const nearNamedRecipient =
  "aperture-recipient-requirement-probe-20260822.near";
const nearImplicitRecipient =
  "288736a61dd2d19345a6badd00f067b7e3048826840dbd76e7c68e49de4a5814";
const tronEndpoint = "https://api.trongrid.io";
const tronOwner = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7";
const tronRecipient = "TStRwBaLtnrFbZbh57km22V45KDBTnbbVn";

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
  if (response.status === 429 && attempt < 4) {
    await new Promise((resolve) => {
      setTimeout(resolve, 1_250 * (attempt + 1));
    });
    return request(url, options, attempt + 1);
  }
  const body = await response.text();
  let object;
  try {
    object = JSON.parse(body);
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

async function verifyStellarAt(endpoint) {
  const [account, ledgers, fees] = await Promise.all([
    request(`${endpoint}/accounts/${stellarRecipient}`),
    request(`${endpoint}/ledgers?order=desc&limit=1`),
    request(`${endpoint}/fee_stats`),
  ]);
  assert(
    account.status === 404,
    `Stellar probe account unexpectedly exists (HTTP ${account.status})`,
  );
  assert(ledgers.status === 200, `Stellar ledgers HTTP ${ledgers.status}`);
  assert(fees.status === 200, `Stellar fee stats HTTP ${fees.status}`);
  const ledger = ledgers.object?._embedded?.records?.[0];
  const baseReserve = ledger?.base_reserve_in_stroops;
  const recommendedFee = fees.object?.fee_charged?.p95;
  assert(/^\d+$/.test(baseReserve ?? ""), "Stellar base reserve is invalid");
  assert(
    /^\d+$/.test(recommendedFee ?? "") && BigInt(recommendedFee) > 0n,
    "Stellar fee state is invalid",
  );
  const minimum = BigInt(baseReserve) * 2n;
  assert(minimum > 0n, "Stellar destination minimum is zero");
  return `stellar: endpoint=${endpoint} inactive=true base_reserve_stroops=${baseReserve} destination_minimum_stroops=${minimum}`;
}

async function verifyStellar() {
  const failures = [];
  for (const endpoint of stellarEndpoints) {
    try {
      return await verifyStellarAt(endpoint);
    } catch (error) {
      failures.push(`${endpoint}: ${error.message}`);
    }
  }
  throw new Error(`Stellar endpoints failed: ${failures.join("; ")}`);
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
  const [account, state] = await Promise.all([
    xrpRPC("account_info", {
      account: xrpRecipient,
      ledger_index: "validated",
      strict: true,
    }),
    xrpRPC("server_state"),
  ]);
  assert(
    account?.status === "error" &&
      ["actNotFound", "accountNotFound"].includes(account?.error),
    "XRP probe account unexpectedly exists or returned an unknown schema",
  );
  const ledger = state?.state?.validated_ledger;
  assert(state?.status === "success", "XRP server_state failed");
  assert(
    Number.isSafeInteger(ledger?.reserve_base) && ledger.reserve_base > 0,
    "XRP base reserve is invalid",
  );
  assert(
    Number.isSafeInteger(ledger?.reserve_inc) && ledger.reserve_inc > 0,
    "XRP owner reserve is invalid",
  );
  return `xrp: inactive=true destination_minimum_drops=${ledger.reserve_base} owner_reserve_drops=${ledger.reserve_inc}`;
}

async function solanaRPCAt(endpoint, method, params) {
  const { status, object } = await postJSON(endpoint, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  });
  assert(status === 200, `Solana ${method}: HTTP ${status}`);
  if (object?.error) {
    throw new Error(
      `Solana ${method}: RPC ${object.error.code} ${object.error.message}`,
    );
  }
  assert(object?.result !== undefined, `Solana ${method}: missing result`);
  return object.result;
}

async function verifySolanaAt(endpoint) {
  const [account, rent] = await Promise.all([
    solanaRPCAt(endpoint, "getAccountInfo", [
      solanaRecipient,
      { commitment: "confirmed", encoding: "base64" },
    ]),
    solanaRPCAt(endpoint, "getMinimumBalanceForRentExemption", [0]),
  ]);
  assert(account?.value === null, "Solana probe account unexpectedly exists");
  assert(Number.isSafeInteger(rent) && rent > 0, "Solana rent is invalid");
  return `solana: endpoint=${endpoint} inactive=true destination_minimum_lamports=${rent} data_length=0`;
}

async function verifySolana() {
  const failures = [];
  for (const endpoint of solanaEndpoints) {
    try {
      return await verifySolanaAt(endpoint);
    } catch (error) {
      failures.push(`${endpoint}: ${error.message}`);
    }
  }
  throw new Error(`Solana endpoints failed: ${failures.join("; ")}`);
}

async function nearAccountResult(endpoint, accountID) {
  const { status, object } = await postJSON(endpoint, {
    jsonrpc: "2.0",
    id: "aperture-recipient-requirement-verification",
    method: "query",
    params: {
      request_type: "view_account",
      finality: "final",
      account_id: accountID,
    },
  });
  assert(status === 200, `NEAR query HTTP ${status}`);
  return object;
}

function isNearUnknownAccount(result) {
  const errorText = JSON.stringify(result?.error ?? {}).toLowerCase();
  return (
    errorText.includes("unknown_account") ||
    errorText.includes("unknown account") ||
    errorText.includes("does not exist while viewing")
  );
}

async function verifyNEAR() {
  const schemas = [];
  for (const endpoint of nearEndpoints) {
    const [named, implicit] = await Promise.all([
      nearAccountResult(endpoint, nearNamedRecipient),
      nearAccountResult(endpoint, nearImplicitRecipient),
    ]);
    for (const [kind, result] of [
      ["named", named],
      ["implicit", implicit],
    ]) {
      assert(
        isNearUnknownAccount(result),
        `NEAR ${kind} probe account unexpectedly exists at ${endpoint}`,
      );
    }
    const implicitError = JSON.stringify(implicit.error).toLowerCase();
    const schema = [];
    if (implicitError.includes("unknown_account")) {
      schema.push("structured_unknown_account");
    }
    if (implicitError.includes("does not exist while viewing")) {
      schema.push("provider_text");
    }
    schemas.push(schema.join("+") || "unknown_account_text");
  }
  return `near: endpoints=${nearEndpoints.length} schemas=${schemas.join(",")} named_inactive=true native_named_blocked=true implicit_inactive=true implicit_transfer_minimum=none`;
}

async function tronPOST(path, body) {
  const { status, object } = await postJSON(`${tronEndpoint}/${path}`, body);
  assert(status === 200, `TRON ${path}: HTTP ${status}`);
  return object;
}

async function verifyTRON() {
  const [account, parameters, unsigned] = await Promise.all([
    tronPOST("wallet/getaccount", {
      address: tronRecipient,
      visible: true,
    }),
    tronPOST("wallet/getchainparameters", {}),
    tronPOST("wallet/createtransaction", {
      owner_address: tronOwner,
      to_address: tronRecipient,
      amount: 1,
      visible: true,
    }),
  ]);
  assert(
    account && Object.keys(account).length === 0,
    "TRON probe account unexpectedly exists",
  );
  const values = Object.fromEntries(
    (parameters?.chainParameter ?? []).map((row) => [row.key, row.value]),
  );
  const activationFee = values.getCreateNewAccountFeeInSystemContract;
  const activationBandwidthFee = values.getCreateAccountFee;
  assert(
    Number.isSafeInteger(activationFee) && activationFee >= 0,
    "TRON activation fee is invalid",
  );
  assert(
    Number.isSafeInteger(activationBandwidthFee) &&
      activationBandwidthFee >= 0,
    "TRON activation bandwidth fee is invalid",
  );
  assert(
    typeof unsigned?.txID === "string" && unsigned.txID.length === 64,
    "TRON one-sun transfer was not constructed",
  );
  return `tron: inactive=true one_sun_transfer_constructed=true transfer_minimum_sun=1 activation_fee_sun=${activationFee} activation_bandwidth_fee_sun=${activationBandwidthFee}`;
}

const results = [];
for (const [name, verification] of [
  ["Stellar", verifyStellar],
  ["XRP", verifyXRP],
  ["Solana", verifySolana],
  ["NEAR", verifyNEAR],
  ["TRON", verifyTRON],
]) {
  const started = Date.now();
  try {
    results.push(`PASS ${await verification()} duration_ms=${Date.now() - started}`);
  } catch (error) {
    throw new Error(`${name} recipient verification failed: ${error.message}`);
  }
}

console.log(results.join("\n"));
