// Independent Node implementation used only for protocol fixtures/integration.
// Never import this test module into the app, worker, or browser bundle.
import { createCipheriv, createDecipheriv, createHash, createPrivateKey, createPublicKey, diffieHellman, hkdfSync, randomBytes } from 'node:crypto';

export const hex = bytes => '\\x'+Buffer.from(bytes).toString('hex');
export const unhex = value => Buffer.from(value.replace(/^\\x/,''),'hex');
export const sha256 = bytes => createHash('sha256').update(bytes).digest();
export const privateKey = raw => createPrivateKey({ key:Buffer.concat([Buffer.from('302e020100300506032b656e04220420','hex'),raw]), format:'der', type:'pkcs8' });
export const publicBytes = rawPrivate => createPublicKey(privateKey(rawPrivate)).export({format:'der',type:'spki'}).subarray(-32);
const publicKey = raw => createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b656e032100','hex'),raw]),format:'der',type:'spki'});
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value==='object' ? Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])) : value;
export const encode = value => Buffer.from(JSON.stringify(canonical(value)));
export function seal(key, plain, aad, nonce=randomBytes(12)) {
  const cipher=createCipheriv('aes-256-gcm',key,nonce); cipher.setAAD(aad);
  return Buffer.concat([nonce,cipher.update(plain),cipher.final(),cipher.getAuthTag()]);
}
export function open(key, bytes, aad) {
  const cipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(0,12)); cipher.setAAD(aad); cipher.setAuthTag(bytes.subarray(-16));
  return JSON.parse(Buffer.concat([cipher.update(bytes.subarray(12,-16)),cipher.final()]));
}
export const eventAAD = (account,id,device,epoch=1,format=1) => Buffer.from(`science-reader/event/v1\n${account.toLowerCase()}\n${id.toLowerCase()}\n${device.toLowerCase()}\n${epoch}\n${format}\n`);
export const recoveryKey = (code,account) => Buffer.from(hkdfSync('sha256',Buffer.from(code.replace(/[-\s]/g,'').toLowerCase(),'hex'),Buffer.from(account.toLowerCase()),Buffer.from('science-reader/recovery/v1'),32));
export const recoveryAAD = account => Buffer.from('science-reader/recovery/v1/'+account.toLowerCase());
export const deviceContext = (account,device,epoch,challenge) => Buffer.concat([Buffer.from(`science-reader/device-envelope/v1/${account.toLowerCase()}/${device.toLowerCase()}/${epoch}/`),challenge]);
export function wrapDevice(bundle,device,recipient,challenge,ephemeral=randomBytes(32),nonce=randomBytes(12)) {
  const ephemeralPublic=publicBytes(ephemeral);
  const context=deviceContext(bundle.accountID,device,bundle.epoch,challenge);
  const secret=diffieHellman({privateKey:privateKey(ephemeral),publicKey:publicKey(recipient)});
  const key=Buffer.from(hkdfSync('sha256',secret,context,Buffer.concat([ephemeralPublic,recipient]),32));
  return Buffer.concat([ephemeralPublic,seal(key,encode(bundle),Buffer.concat([context,ephemeralPublic,recipient]),nonce)]);
}
export function unwrapDevice(bytes,account,device,epoch,rawPrivate,challenge) {
  const ephemeral=bytes.subarray(0,32), recipient=publicBytes(rawPrivate);
  const context=deviceContext(account,device,epoch,challenge);
  const secret=diffieHellman({privateKey:privateKey(rawPrivate),publicKey:publicKey(ephemeral)});
  const key=Buffer.from(hkdfSync('sha256',secret,context,Buffer.concat([ephemeral,recipient]),32));
  return open(key,bytes.subarray(32),Buffer.concat([context,ephemeral,recipient]));
}
