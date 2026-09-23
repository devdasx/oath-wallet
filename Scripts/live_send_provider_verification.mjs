#!/usr/bin/env node

const evmNetworks = [
  ["eth", 1, "https://ethereum-rpc.publicnode.com"],
  ["bsc", 56, "https://bsc-rpc.publicnode.com"],
  ["arbitrum", 42161, "https://arbitrum-one-rpc.publicnode.com"],
  ["base", 8453, "https://base-rpc.publicnode.com"],
  ["polygon", 137, "https://polygon-bor-rpc.publicnode.com"],
  ["optimism", 10, "https://optimism-rpc.publicnode.com"],
  ["avalanche", 43114, "https://avalanche-c-chain-rpc.publicnode.com"],
  ["gnosis", 100, "https://gnosis-rpc.publicnode.com"],
  ["linea", 59144, "https://linea-rpc.publicnode.com"],
  ["scroll", 534352, "https://scroll-rpc.publicnode.com"],
  ["taiko", 167000, "https://taiko-rpc.publicnode.com"],
  ["telos", 40, "https://rpc.telos.net"],
  ["xlayer", 196, "https://rpc.xlayer.tech"],
];

const solanaEndpoint = "https://api.mainnet-beta.solana.com";
const solanaWallet = "D89hHJT5Aqyx1trP6EnGY9jJUB3whgnq3aUvvCqedvzf";
const solanaUSDCMint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const solanaUSDCTokenAccount =
  "ZaUEpMj6qeBDGRwxJxUvXmuQbjR1dqSHgqx23Chzobq";
const solanaSystemProgram = "11111111111111111111111111111111";
const solanaTokenProgram =
  "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const solanaToken2022Program =
  "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
const solanaToken2022Account =
  "3PaFQnebQMHBgthRScup2B932cMxA1GBP7m9roCkomHq";

const tronEndpoint =
  "https://aperture-notifications.devdas98x.workers.dev" +
  "/v1/provider/ankr/tron/rest";
const tronPublicEndpoint = "https://api.trongrid.io";
const tronOwner = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7";
const tronRecipient = "TE4qktKPi9FYDDvydfrikbXu6JFU5uCtYf";
const tronUSDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

async function jsonRequest(url, body, attempt = 0) {
  const response = await fetch(url, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  if (response.status === 429 && attempt < 5) {
    await new Promise((resolve) => {
      setTimeout(resolve, 1_500 * (attempt + 1));
    });
    return jsonRequest(url, body, attempt + 1);
  }
  const text = await response.text();
  let object;
  try {
    object = JSON.parse(text);
  } catch {
    throw new Error(`non-JSON response (${response.status})`);
  }
  return { status: response.status, object };
}

async function evmRPC(url, method, params) {
  const { status, object } = await jsonRequest(url, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  });
  assert(status === 200, `${method}: HTTP ${status}`);
  if (object.error) {
    throw new Error(
      `${method}: RPC ${object.error.code} ${object.error.message}`,
    );
  }
  assert(object.result !== undefined, `${method}: missing result`);
  return object.result;
}

async function evmInvalidBroadcastIsRejected(url) {
  const { object } = await jsonRequest(url, {
    jsonrpc: "2.0",
    id: 1,
    method: "eth_sendRawTransaction",
    params: ["0x00"],
  });
  assert(
    object?.error && Number.isInteger(object.error.code),
    "eth_sendRawTransaction: invalid transaction was not rejected",
  );
}

async function verifyEVM([id, expectedChainID, url]) {
  const sampleAddress = "0x000000000000000000000000000000000000dEaD";
  const started = Date.now();
  const [chainID, nonce, balance, gas] = await Promise.all([
    evmRPC(url, "eth_chainId", []),
    evmRPC(url, "eth_getTransactionCount", [sampleAddress, "pending"]),
    evmRPC(url, "eth_getBalance", [sampleAddress, "pending"]),
    evmRPC(url, "eth_estimateGas", [
      {
        from: sampleAddress,
        to: sampleAddress,
        value: "0x0",
      },
    ]),
    evmInvalidBroadcastIsRejected(url),
  ]);
  assert(
    Number.parseInt(chainID, 16) === expectedChainID,
    `${id}: chain ID mismatch`,
  );
  for (const [name, value] of [
    ["nonce", nonce],
    ["balance", balance],
    ["gas", gas],
  ]) {
    assert(/^0x[0-9a-f]+$/i.test(value), `${id}: invalid ${name}`);
  }
  assert(BigInt(balance) > 0n, `${id}: Max probe account is unfunded`);
  const maximumProbe = await evmRPC(url, "eth_estimateGas", [
    {
      from: sampleAddress,
      to: "0x000000000000000000000000000000000000bEEF",
      // These rollups charge L1 data separately even when execution gas is 0.
      // Match the production Max probe's conservative native reserve.
      value: "0x" + (BigInt(balance) -
        (["base", "optimism", "scroll"].includes(id) ? 10_000_000_000_000n : 0n)
      ).toString(16),
      gasPrice: "0x0",
    },
  ]);
  assert(/^0x[0-9a-f]+$/i.test(maximumProbe), `${id}: invalid Max probe`);
  return `${id}: chain=${expectedChainID} max_probe=${Number.parseInt(maximumProbe, 16)} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function verifyEVMTokenMaximum() {
  const url = evmNetworks[0][2];
  const owner = "0x000000000000000000000000000000000000dEaD";
  const recipient = "000000000000000000000000000000000000beef";
  const weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const balanceData = "0x70a08231" + owner.slice(2).padStart(64, "0");
  const [balance, priorityFee, latestBlock] = await Promise.all([
    evmRPC(url, "eth_call", [{ to: weth, data: balanceData }, "pending"]),
    evmRPC(url, "eth_maxPriorityFeePerGas", []),
    evmRPC(url, "eth_getBlockByNumber", ["latest", false]),
  ]);
  assert(BigInt(balance) > 0n, "Ethereum WETH Max probe is unfunded");
  assert(
    /^0x[0-9a-f]+$/i.test(latestBlock?.baseFeePerGas ?? ""),
    "Ethereum base fee is invalid",
  );
  const maximumFee =
    BigInt(latestBlock.baseFeePerGas) * 2n + BigInt(priorityFee);
  const transferData =
    "0xa9059cbb" +
    recipient.padStart(64, "0") +
    balance.slice(2).padStart(64, "0");
  const estimate = await evmRPC(url, "eth_estimateGas", [
    {
      from: owner,
      to: weth,
      value: "0x0",
      data: transferData,
      maxFeePerGas: `0x${maximumFee.toString(16)}`,
      maxPriorityFeePerGas: priorityFee,
    },
  ]);
  assert(/^0x[0-9a-f]+$/i.test(estimate), "WETH Max estimate is invalid");
  return `ethereum_erc20_max: exact_balance=verified gas=${Number.parseInt(estimate, 16)}`;
}

async function solanaRPC(method, params) {
  const { status, object } = await jsonRequest(solanaEndpoint, {
    jsonrpc: "2.0",
    id: 1,
    method,
    params,
  });
  assert(status === 200, `solana ${method}: HTTP ${status}`);
  if (object.error) {
    throw new Error(
      `solana ${method}: RPC ${object.error.code} ${object.error.message}`,
    );
  }
  assert(object.result !== undefined, `solana ${method}: missing result`);
  return object.result;
}

const base58Alphabet =
  "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function decodeBase58(value) {
  let number = 0n;
  for (const character of value) {
    const digit = base58Alphabet.indexOf(character);
    assert(digit >= 0, "invalid base58 value");
    number = number * 58n + BigInt(digit);
  }
  const bytes = [];
  while (number > 0n) {
    bytes.push(Number(number & 255n));
    number >>= 8n;
  }
  for (const character of value) {
    if (character !== "1") break;
    bytes.push(0);
  }
  return Buffer.from(bytes.reverse());
}

function encodeShortVector(value) {
  const output = [];
  let remaining = value;
  do {
    let byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining > 0) byte |= 0x80;
    output.push(byte);
  } while (remaining > 0);
  return Buffer.from(output);
}

function unsignedLittleEndian64(value) {
  const data = Buffer.alloc(8);
  data.writeBigUInt64LE(BigInt(value));
  return data;
}

function solanaTransferMessage(blockhash) {
  const payer = decodeBase58(solanaWallet);
  const system = decodeBase58(solanaSystemProgram);
  const recent = decodeBase58(blockhash);
  assert(
    payer.length === 32 && system.length === 32 && recent.length === 32,
    "invalid Solana public key or blockhash",
  );
  const transferData = Buffer.concat([
    Buffer.from([2, 0, 0, 0]),
    unsignedLittleEndian64(0),
  ]);
  return Buffer.concat([
    Buffer.from([1, 0, 1]),
    encodeShortVector(2),
    payer,
    system,
    recent,
    encodeShortVector(1),
    Buffer.from([1]),
    encodeShortVector(1),
    Buffer.from([0]),
    encodeShortVector(transferData.length),
    transferData,
  ]).toString("base64");
}

async function solanaInvalidBroadcastIsRejected() {
  const { object } = await jsonRequest(solanaEndpoint, {
    jsonrpc: "2.0",
    id: 1,
    method: "sendTransaction",
    params: [
      "AA==",
      {
        encoding: "base64",
        preflightCommitment: "confirmed",
        skipPreflight: false,
        maxRetries: 5,
      },
    ],
  });
  assert(
    object?.error && Number.isInteger(object.error.code),
    "Solana invalid transaction was not rejected",
  );
}

async function verifySolana() {
  const started = Date.now();
  const [
    latest,
    balance,
    mint,
    rent,
    tokenBalance,
    token2022Account,
  ] = await Promise.all([
    solanaRPC("getLatestBlockhash", [{ commitment: "confirmed" }]),
    solanaRPC("getBalance", [solanaWallet, { commitment: "confirmed" }]),
    solanaRPC("getAccountInfo", [
      solanaUSDCMint,
      { commitment: "confirmed", encoding: "base64" },
    ]),
    solanaRPC("getMinimumBalanceForRentExemption", [165]),
    solanaRPC("getTokenAccountBalance", [
      solanaUSDCTokenAccount,
      { commitment: "confirmed" },
    ]),
    solanaRPC("getAccountInfo", [
      solanaToken2022Account,
      { commitment: "confirmed", encoding: "base64" },
    ]),
    solanaInvalidBroadcastIsRejected(),
  ]);
  const blockhash = latest?.value?.blockhash;
  assert(typeof blockhash === "string", "Solana blockhash is missing");
  assert(Number.isSafeInteger(balance?.value), "Solana balance is invalid");
  assert(
    mint?.value?.owner === solanaTokenProgram,
    "Solana USDC mint owner mismatch",
  );
  assert(Number.isSafeInteger(rent) && rent > 0, "Solana rent is invalid");
  assert(
    /^\d+$/.test(tokenBalance?.value?.amount ?? ""),
    "Solana token balance is invalid",
  );
  assert(
    token2022Account?.value?.owner === solanaToken2022Program,
    "Solana Token-2022 account owner mismatch",
  );
  const token2022DataLength = Buffer.from(
    token2022Account.value.data[0],
    "base64",
  ).length;
  assert(
    token2022DataLength > 165,
    "Solana Token-2022 account did not exercise dynamic rent",
  );
  const token2022Rent = await solanaRPC(
    "getMinimumBalanceForRentExemption",
    [token2022DataLength],
  );
  assert(
    Number.isSafeInteger(token2022Rent) && token2022Rent > rent,
    "Solana Token-2022 rent is invalid",
  );
  const fee = await solanaRPC("getFeeForMessage", [
    solanaTransferMessage(blockhash),
    { commitment: "confirmed" },
  ]);
  assert(Number.isSafeInteger(fee?.value), "Solana message fee is invalid");
  return `solana: token_balance=verified token2022_bytes=${token2022DataLength} token2022_rent=${token2022Rent} message_fee=${fee.value} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

async function tronPost(path, body) {
  const { status, object } = await jsonRequest(
    `${tronEndpoint}/wallet/${path}`,
    body,
  );
  assert(status === 200, `TRON ${path}: HTTP ${status}`);
  if (object?.Error) throw new Error(`TRON ${path}: ${object.Error}`);
  return object;
}

async function tronPublicPost(path, body = {}) {
  const { status, object } = await jsonRequest(
    `${tronPublicEndpoint}/wallet/${path}`,
    body,
  );
  assert(status === 200, `TRON public ${path}: HTTP ${status}`);
  if (object?.Error) throw new Error(`TRON public ${path}: ${object.Error}`);
  return object;
}

function protobufVarintBytes(value) {
  let remaining = value;
  let count = 1;
  while (remaining >= 0x80) {
    remaining = Math.floor(remaining / 0x80);
    count += 1;
  }
  return count;
}

async function verifyTronConsensusFees() {
  const [parameters, latest] = await Promise.all([
    tronPublicPost("getchainparameters"),
    tronPublicPost("getnowblock"),
  ]);
  const values = Object.fromEntries(
    (parameters.chainParameter ?? []).map((row) => [row.key, row.value]),
  );
  for (const key of [
    "getEnergyFee",
    "getTransactionFee",
    "getCreateAccountFee",
    "getCreateNewAccountFeeInSystemContract",
    "getCreateNewAccountBandwidthRate",
  ]) {
    assert(Number.isSafeInteger(values[key]), `TRON missing ${key}`);
  }

  const latestNumber = latest?.block_header?.raw_data?.number;
  assert(Number.isSafeInteger(latestNumber), "TRON latest block is invalid");
  const block = await tronPublicPost("getblockbynum", {
    num: latestNumber - 50,
  });
  const candidates = (block.transactions ?? []).filter(
    (transaction) =>
      transaction?.raw_data?.contract?.[0]?.type === "TransferContract" &&
      transaction?.signature?.length === 1 &&
      typeof transaction?.raw_data_hex === "string",
  );
  assert(candidates.length > 0, "TRON block has no native transfer sample");
  let verifiedTransaction;
  for (const transaction of candidates.slice(0, 8)) {
    const rawDataBytes = transaction.raw_data_hex.length / 2;
    const bandwidthBytes =
      rawDataBytes +
      1 +
      protobufVarintBytes(rawDataBytes) +
      67 +
      64;
    const info = await tronPublicPost("gettransactioninfobyid", {
      value: transaction.txID,
    });
    const paidByResource = info?.receipt?.net_usage === bandwidthBytes;
    const paidByBalance =
      info?.receipt?.net_fee === bandwidthBytes * values.getTransactionFee;
    if (paidByResource || paidByBalance) {
      verifiedTransaction = { transaction, rawDataBytes, bandwidthBytes };
      break;
    }
  }
  assert(verifiedTransaction, "TRON signed bandwidth formula did not match");
  assert(
    verifiedTransaction.transaction.signature[0].length / 2 === 65,
    "TRON signature length mismatch",
  );

  const inactiveAddress = "TStRwBaLtnrFbZbh57km22V45KDBTnbbVn";
  const inactive = await tronPublicPost("getaccount", {
    address: inactiveAddress,
    visible: true,
  });
  assert(
    Object.keys(inactive).length === 0,
    "TRON inactive-account fixture became active",
  );
  return `tron_consensus: raw_bytes=${verifiedTransaction.rawDataBytes} signed_bandwidth_bytes=${verifiedTransaction.bandwidthBytes} inactive_account=verified activation_fee=${values.getCreateNewAccountFeeInSystemContract} create_bandwidth_fee=${values.getCreateAccountFee}`;
}

function tronABIAddress(address = tronOwner) {
  const decoded = decodeBase58(address);
  assert(
    decoded.length === 25 && decoded[0] === 0x41,
    "invalid TRON address",
  );
  return Buffer.concat([
    Buffer.alloc(12),
    decoded.subarray(1, 21),
  ]).toString("hex");
}

function tronTransferParameter() {
  return tronABIAddress() + "1".padStart(64, "0");
}

async function tronInvalidBroadcastIsRejected(unsignedTransaction) {
  const signedTransaction = {
    ...unsignedTransaction,
    signature: ["00".repeat(65)],
  };
  const { status, object } = await jsonRequest(
    `${tronEndpoint}/wallet/broadcasttransaction`,
    {
      signed_transaction_json: JSON.stringify(signedTransaction),
    },
  );
  assert(
    status === 200 &&
      (object?.result === false || typeof object?.code === "string"),
    "TRON invalid transaction was not rejected",
  );
}

async function verifyTron() {
  const started = Date.now();
  const [
    account,
    resource,
    tokenBalance,
    nativeTransaction,
    tokenTransaction,
    estimate,
  ] = await Promise.all([
    tronPost("getaccount", {
      address: tronOwner,
      visible: true,
    }),
    tronPost("getaccountresource", {
      address: tronOwner,
      visible: true,
    }),
    tronPost("triggerconstantcontract", {
      owner_address: tronOwner,
      contract_address: tronUSDT,
      function_selector: "balanceOf(address)",
      parameter: tronABIAddress(),
      visible: true,
    }),
    tronPost("createtransaction", {
      owner_address: tronOwner,
      to_address: tronRecipient,
      amount: "1",
      visible: true,
    }),
    tronPost("triggersmartcontract", {
      owner_address: tronOwner,
      contract_address: tronUSDT,
      function_selector: "transfer(address,uint256)",
      parameter: tronTransferParameter(),
      fee_limit: "30000000",
      call_value: "0",
      visible: true,
    }),
    tronPost("estimateenergy", {
      owner_address: tronOwner,
      contract_address: tronUSDT,
      function_selector: "transfer(address,uint256)",
      parameter: tronTransferParameter(),
      visible: true,
    }),
  ]);
  await tronInvalidBroadcastIsRejected(nativeTransaction);
  assert(
    account && typeof account === "object",
    "TRON account response is invalid",
  );
  assert(
    resource && typeof resource === "object",
    "TRON resource response is invalid",
  );
  assert(
    tokenBalance?.result?.result === true &&
      Array.isArray(tokenBalance?.constant_result),
    "TRON token balance response is invalid",
  );
  assert(
    /^[0-9a-f]{64}$/i.test(nativeTransaction?.txID ?? "") &&
      typeof nativeTransaction?.raw_data_hex === "string",
    "TRON native transaction response is invalid",
  );
  assert(
    tokenTransaction?.result?.result === true &&
      /^[0-9a-f]{64}$/i.test(tokenTransaction?.transaction?.txID ?? "") &&
      typeof tokenTransaction?.transaction?.raw_data_hex === "string",
    "TRON token transaction response is invalid",
  );

  assert(
    estimate?.result?.result === true,
    "TRON estimateenergy rejected",
  );
  const energy = estimate.energy_required;
  assert(Number.isSafeInteger(energy) && energy > 0, "TRON energy is invalid");
  return `tron: native_build=verified trc20_build=verified energy=${energy} invalid_broadcast=verified duration_ms=${Date.now() - started}`;
}

// Report every chain even if one provider fails, rather than losing successful
// results behind Promise.all's first rejection. No valid signatures are sent.
const checks = [
  ...evmNetworks.map((network) => [network[0], () => verifyEVM(network)]),
  ["evm_token_max", verifyEVMTokenMaximum],
  ["solana", verifySolana],
  ["tron", verifyTron],
  ["tron_consensus", verifyTronConsensusFees],
];
const results = await Promise.allSettled(checks.map(([, run]) => run()));
for (let index = 0; index < results.length; index++) {
  const result = results[index];
  if (result.status === "fulfilled") process.stdout.write(`${result.value}\n`);
  else {
    process.stderr.write(`${checks[index][0]}: FAILED ${result.reason.message}\n`);
    process.exitCode = 1;
  }
}
