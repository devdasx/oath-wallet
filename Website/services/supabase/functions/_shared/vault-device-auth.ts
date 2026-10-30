// Device IDs are labels, never credentials. Every protected request proves
// possession of the enrolled P-256 key and consumes a durable one-use nonce.
export type RPC = (name: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
export interface DeviceAuthorization {
  keyID: string; installationID: string; publicKey: string;
  approved: boolean; appAccessEnabled: boolean; sensitiveDataEnabled: boolean; isOwner: boolean;
}
export class DeviceAuthorizationError extends Error {
  status: number;
  constructor(status = 403) { super("device_access_unavailable"); this.status = status; }
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map(x => x.toString(16).padStart(2,"0")).join("");
const encoder = new TextEncoder();
export const digest = async (value: Uint8Array) => hex(await crypto.subtle.digest("SHA-256", value as BufferSource));
export function canonicalRequest(endpoint: string, installationID: string, keyID: string,
  timestamp: string, nonce: string, bodyHash: string): string {
  return ["vault-device-v1", "POST", endpoint, installationID, keyID, timestamp, nonce, bodyHash].join("\n");
}
function decode(value: string): Uint8Array {
  try { return Uint8Array.from(atob(value), c => c.charCodeAt(0)); }
  catch { throw new DeviceAuthorizationError(); }
}
export async function authorizeDevice(request: Request, body: string, endpoint: string, rpc: RPC,
  enrollment?: {publicKey: string; deviceName: string; osDescription: string}): Promise<DeviceAuthorization> {
  if (request.method !== "POST") throw new DeviceAuthorizationError();
  const installationID = request.headers.get("x-vault-installation-id") ?? "";
  const keyID = request.headers.get("x-vault-key-id") ?? "";
  const timestamp = request.headers.get("x-vault-timestamp") ?? "";
  const nonce = request.headers.get("x-vault-nonce") ?? "";
  const signature = request.headers.get("x-vault-signature") ?? "";
  if (!uuid.test(installationID) || !uuid.test(nonce) || !/^[0-9a-f]{64}$/.test(keyID) ||
      !/^[0-9]{10}$/.test(timestamp) || Math.abs(Date.now()/1000 - Number(timestamp)) > 90 ||
      signature.length !== 88) throw new DeviceAuthorizationError();
  let publicKey = enrollment?.publicKey;
  if (!publicKey) {
    const { data, error } = await rpc("vault_device_key", {p_key_id:keyID});
    if (error) throw new DeviceAuthorizationError(503);
    if (typeof data !== "string") throw new DeviceAuthorizationError();
    publicKey = data;
  }
  const rawKey = decode(publicKey);
  const rawSignature = decode(signature);
  if (rawKey.length !== 65 || rawKey[0] !== 4 || rawSignature.length !== 64 || await digest(rawKey) !== keyID)
    throw new DeviceAuthorizationError();
  try {
    const key = await crypto.subtle.importKey("raw",rawKey as BufferSource,{name:"ECDSA",namedCurve:"P-256"},false,["verify"]);
    const message = canonicalRequest(endpoint,installationID,keyID,timestamp,nonce,await digest(encoder.encode(body)));
    if (!await crypto.subtle.verify({name:"ECDSA",hash:"SHA-256"},key,rawSignature as BufferSource,encoder.encode(message)))
      throw new DeviceAuthorizationError();
  } catch { throw new DeviceAuthorizationError(); }
  if (enrollment) {
    const {error} = await rpc("vault_enroll_device", {p_key_id:keyID,p_public_key:publicKey,
      p_installation_id:installationID,p_device_name:enrollment.deviceName,p_os_description:enrollment.osDescription});
    if (error) throw new DeviceAuthorizationError();
  }
  const {data,error} = await rpc("vault_authorize_device_request", {
    p_key_id:keyID,p_installation_id:installationID,p_nonce:nonce,p_timestamp:Number(timestamp),
  });
  if (error || !data || typeof data !== "object") throw new DeviceAuthorizationError();
  const value = data as DeviceAuthorization;
  if (value.keyID !== keyID || value.installationID !== installationID ||
      [value.approved,value.appAccessEnabled,value.sensitiveDataEnabled,value.isOwner].some(x => typeof x !== "boolean"))
    throw new DeviceAuthorizationError();
  return value;
}
export function requireAppAccess(value: DeviceAuthorization): void {
  if (!value.approved || !value.appAccessEnabled) throw new DeviceAuthorizationError();
}
export function requireOwner(value: DeviceAuthorization): void {
  requireAppAccess(value);
  if (!value.isOwner) throw new DeviceAuthorizationError();
}
export function deviceError(error: unknown): Response {
  return new Response(JSON.stringify({error:"device_access_unavailable"}),{status:error instanceof DeviceAuthorizationError ? error.status : 503,
    headers:{"Content-Type":"application/json","Cache-Control":"no-store"}});
}
