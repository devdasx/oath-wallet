#!/usr/bin/env node

import tls from "node:tls";
import { createHash } from "node:crypto";

const chains = [
  {
    id: "bitcoin",
    host: "electrum.blockstream.info",
    port: 50002,
    genesis:
      "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    scriptHash:
      "f50f038feec6468737d11227b2e4f375188a0ebdca9b09c0f71528119a7267a6",
    params: (hash) => [hash],
    broadcast: {
      url: "https://mempool.space/api/tx",
      contentType: "text/plain; charset=utf-8",
      body: "00",
    },
  },
  {
    id: "bitcoin_cash",
    host: "cashnode.bch.ninja",
    port: 50002,
    genesis:
      "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
    scriptHash:
      "b55f0bae3e2bbbf3f22f3e9215983023597b6b98a86b9b16bc2a772772796c73",
    params: (hash) => [hash, "exclude_tokens"],
    broadcast: {
      url: "https://api.bitcore.io/api/BCH/mainnet/tx/send",
      contentType: "application/json",
      body: JSON.stringify({ rawTx: "00" }),
    },
  },
  {
    id: "litecoin",
    host: "litecoin.stackwallet.com",
    port: 20063,
    genesis:
      "12a765e31ffd4059bada1e25190f6e98c99d9714d334efa41a195a7e7e04bfe2",
    scriptHash:
      "fca0ea2fde16fe2d96482cfd3e47fcc66b344008d800f19936cc7fd8de189206",
    params: (hash) => [hash],
    broadcast: {
      url: "https://litecoinspace.org/api/tx",
      contentType: "text/plain; charset=utf-8",
      body: "00",
    },
  },
  {
    id: "dogecoin",
    host: "dogecoin.stackwallet.com",
    port: 50022,
    genesis:
      "1a91e3dace36e2be3bf030a65679fe821aa1d6ef92e7c9902eb318182c355691",
    scriptHash:
      "b7005bfeaa2be98a42632ca9f9a44f10011edf1777a4fc2bb8bb306c7c8106da",
    params: (hash) => [hash],
    broadcast: {
      url: "https://dogecoin.atomicwallet.io/api/v2/sendtx/",
      contentType: "text/plain; charset=utf-8",
      body: "00",
    },
  },
];

function rpc(config, method, params) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({
      host: config.host,
      port: config.port,
      servername: config.host,
      rejectUnauthorized: true,
    });
    let buffer = "";
    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error(`${config.id}: timed out`));
    }, 12_000);
    socket.setEncoding("utf8");
    socket.on("secureConnect", () => {
      socket.write(
        `${JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          method,
          params,
        })}\n`,
      );
    });
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      clearTimeout(timeout);
      socket.end();
      try {
        const response = JSON.parse(buffer.slice(0, newline));
        if (response.error) {
          reject(
            new Error(
              `${config.id}: RPC ${response.error.code} ${response.error.message}`,
            ),
          );
          return;
        }
        resolve(response.result);
      } catch (error) {
        reject(error);
      }
    });
    socket.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
  });
}

function assertUTXOs(config, outputs) {
  if (!Array.isArray(outputs) || outputs.length === 0) {
    throw new Error(`${config.id}: expected a non-empty UTXO array`);
  }
  for (const output of outputs) {
    if (
      typeof output.tx_hash !== "string" ||
      !/^[0-9a-f]{64}$/.test(output.tx_hash) ||
      !Number.isSafeInteger(output.tx_pos) ||
      output.tx_pos < 0 ||
      output.tx_pos > 0xffff_ffff ||
      !Number.isSafeInteger(output.value) ||
      output.value <= 0 ||
      !Number.isSafeInteger(output.height)
    ) {
      throw new Error(`${config.id}: invalid listunspent output schema`);
    }
  }
}

function blockHash(header) {
  if (typeof header !== "string" || !/^[0-9a-f]{160}$/i.test(header)) {
    throw new Error("invalid genesis header schema");
  }
  const first = createHash("sha256")
    .update(Buffer.from(header, "hex"))
    .digest();
  return createHash("sha256")
    .update(first)
    .digest()
    .reverse()
    .toString("hex");
}

async function verifyRejectedBroadcast(config) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12_000);
  let response;
  try {
    response = await fetch(config.broadcast.url, {
      method: "POST",
      headers: {
        Accept: "text/plain, application/json",
        "Content-Type": config.broadcast.contentType,
      },
      body: config.broadcast.body,
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timeout);
  }
  if (response.ok) {
    throw new Error(
      `${config.id}: invalid HTTPS transaction was not rejected`,
    );
  }
}

async function verify(config) {
  const started = Date.now();
  const [outputs, tip, genesisHeader] = await Promise.all([
    rpc(
      config,
      "blockchain.scripthash.listunspent",
      config.params(config.scriptHash),
    ),
    rpc(config, "blockchain.headers.subscribe", []),
    rpc(config, "blockchain.block.header", [0]),
    verifyRejectedBroadcast(config),
  ]);
  assertUTXOs(config, outputs);
  if (!tip || !Number.isSafeInteger(tip.height) || tip.height <= 0) {
    throw new Error(`${config.id}: invalid subscribed tip`);
  }
  if (blockHash(genesisHeader) !== config.genesis) {
    throw new Error(`${config.id}: genesis mismatch`);
  }
  return {
    chain: config.id,
    outputs: outputs.length,
    tip: tip.height,
    httpsBroadcastRejection: "verified",
    durationMs: Date.now() - started,
  };
}

const results = await Promise.all(chains.map(verify));
for (const result of results) {
  process.stdout.write(
    `${result.chain}: outputs=${result.outputs} tip=${result.tip} genesis=verified invalid_https_broadcast=${result.httpsBroadcastRejection} duration_ms=${result.durationMs}\n`,
  );
}
