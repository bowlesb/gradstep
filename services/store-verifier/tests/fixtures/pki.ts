// Ephemeral test-only certificates/keys. No production or Apple receipt fixture.
import { createPrivateKey, sign, X509Certificate } from 'node:crypto';
import jsrsasign from 'jsrsasign';
const { KEYUTIL, KJUR } = jsrsasign as unknown as { KEYUTIL: any; KJUR: any };
export interface OCSPTimes { thisUpdate?: string | null; nextUpdate?: string | null; producedAt?: string | null; status?: 'good' | 'unknown' }
export function testPKI(ocspURL: string) {
  const pair = () => KEYUTIL.generateKeypair('EC', 'secp256r1');
  const root = pair(), intermediate = pair(), leaf = pair(), intermediateResponder = pair(), rootResponder = pair();
  const name = (cn: string) => ({ str: `/CN=${cn}/O=Science Reader Tests/C=US` });
  let serial = 1;
  const cert = (subject: string, issuer: string, publicKey: unknown, signer: unknown, ext: unknown[]) => new KJUR.asn1.x509.Certificate({
    version: 3, serial: { int: serial++ }, issuer: name(issuer), subject: name(subject), notbefore: '250101000000Z', notafter: '351231235959Z',
    sbjpubkey: publicKey, sigalg: 'SHA256withECDSA', cakey: signer, ext,
  }).tohex();
  const aia = [{ extname: 'authorityInfoAccess', array: [{ ocsp: ocspURL }] }];
  const rootHex = cert('Root', 'Root', root.pubKeyObj, root.prvKeyObj, [{ extname: 'basicConstraints', critical: true, cA: true }]);
  const intermediateHex = cert('Intermediate', 'Root', intermediate.pubKeyObj, root.prvKeyObj,
    [{ extname: 'basicConstraints', critical: true, cA: true }, { extname: '1.2.840.113635.100.6.2.1', extn: '0500' }, ...aia]);
  const leafHex = cert('Leaf', 'Intermediate', leaf.pubKeyObj, intermediate.prvKeyObj, [{ extname: '1.2.840.113635.100.6.11.1', extn: '0500' }, ...aia]);
  const intermediateResponderHex = cert('Intermediate Responder', 'Intermediate', intermediateResponder.pubKeyObj, intermediate.prvKeyObj,
    [{ extname: 'extKeyUsage', array: ['ocspSigning'] }]);
  const rootResponderHex = cert('Root Responder', 'Root', rootResponder.pubKeyObj, root.prvKeyObj, [{ extname: 'extKeyUsage', array: ['ocspSigning'] }]);
  const pem = (hex: string) => new X509Certificate(Buffer.from(hex, 'hex')).toString();
  const leafKey = createPrivateKey(KEYUTIL.getPEM(leaf.prvKeyObj, 'PKCS8PRV'));
  const time = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, '').replace('T', '').replace(/\.\d{3}/, '');
  const certIds = new KJUR.asn1.ocsp.CertID();
  const leafID = certIds.getParamByCerts(pem(intermediateHex), pem(leafHex), 'sha256');
  const intermediateID = certIds.getParamByCerts(pem(rootHex), pem(intermediateHex), 'sha256');
  return {
    root: Buffer.from(rootHex, 'hex'),
    sign(payload: unknown, tamper = false) {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', x5c: [leafHex, intermediateHex, rootHex].map(h => Buffer.from(h, 'hex').toString('base64')) })).toString('base64url');
      const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
      const signature = sign('sha256', Buffer.from(`${header}.${body}`), { key: leafKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      const sent = tamper ? Buffer.from(JSON.stringify({ ...(payload as object), quantity: 99 })).toString('base64url') : body;
      return `${header}.${sent}.${signature}`;
    },
    ocsp(request: Buffer, status: 'good' | 'revoked' | 'stale' | 'bad_signature' = 'good', times: OCSPTimes = {}) {
      const parsed = new KJUR.asn1.ocsp.OCSPParser().getOCSPRequest(request.toString('hex'));
      const id = parsed.array[0];
      const isLeaf = id.sbjsn === leafID.sbjsn && id.isskey === leafID.isskey;
      const chosen = isLeaf ? leafID : intermediateID;
      if (id.sbjsn !== chosen.sbjsn || id.isskey !== chosen.isskey) throw new Error('unexpected_test_ocsp_request');
      const responder = isLeaf ? intermediateResponder : rootResponder;
      const responderHex = isLeaf ? intermediateResponderHex : rootResponderHex;
      const now = Date.now();
      const thisUpdate = times.thisUpdate === undefined ? time(status === 'stale' ? now - 7_200_000 : now - 60_000) : times.thisUpdate;
      const nextUpdate = times.nextUpdate === undefined ? time(status === 'stale' ? now - 3_600_000 : now + 3_600_000) : times.nextUpdate;
      const producedAt = times.producedAt === undefined ? time(status === 'stale' ? now - 7_200_000 : now) : times.producedAt;
      // ASN.1 builders sign exactly these bytes, including intentionally missing
      // or malformed time values. No mock parser or mock verification result.
      const single = [new KJUR.asn1.ocsp.CertID(chosen), new KJUR.asn1.ocsp.CertStatus(status === 'revoked'
        ? { status: 'revoked', time: time(now - 60_000) } : { status: times.status ?? 'good' })];
      if (thisUpdate !== null) single.push(new KJUR.asn1.DERGeneralizedTime({ str: thisUpdate }));
      if (nextUpdate !== null) single.push(new KJUR.asn1.DERTaggedObject({ tag: 'a0', explicit: true,
        obj: new KJUR.asn1.DERGeneralizedTime({ str: nextUpdate }) }));
      const data = [new KJUR.asn1.ocsp.ResponderID({ name: pem(responderHex) })];
      if (producedAt !== null) data.push(new KJUR.asn1.DERGeneralizedTime({ str: producedAt }));
      data.push(new KJUR.asn1.DERSequence({ array: [new KJUR.asn1.DERSequence({ array: single })] }));
      const response = new KJUR.asn1.ocsp.OCSPResponse({ resstatus: 'successful', restype: 'ocspBasic',
        tbsresp: new KJUR.asn1.DERSequence({ array: data }), sigalg: 'SHA256withECDSA', reskey: responder.prvKeyObj, certs: [responderHex] });
      const bytes = Buffer.from(response.tohex(), 'hex');
      if (status === 'bad_signature') {
        const parsedResponse = new KJUR.asn1.ocsp.OCSPParser().getOCSPResponse(bytes.toString('hex'));
        const hex = bytes.toString('hex'); const offset = hex.indexOf(parsedResponse.sighex);
        bytes[offset / 2 + parsedResponse.sighex.length / 2 - 1] ^= 1;
      }
      return bytes;
    },
  };
}
export const BUNDLE = 'com.sciencereader.ios';
export const transaction = (overrides: Record<string, unknown> = {}) => ({ environment: 'Sandbox', bundleId: BUNDLE,
  transactionId: '2000000123456789', originalTransactionId: '2000000123456789', productId: BUNDLE + '.credits400',
  type: 'Consumable', purchaseDate: Date.now() - 60_000, signedDate: Date.now(), quantity: 1, transactionReason: 'PURCHASE',
  appAccountToken: '01000000-0000-0000-0000-000000000001', ...overrides });
export const notification = (signed: string, overrides: Record<string, unknown> = {}) => ({
  notificationType: 'ONE_TIME_CHARGE', notificationUUID: '02000000-0000-0000-0000-000000000001', version: '2.0', signedDate: Date.now(),
  data: { bundleId: BUNDLE, environment: 'Sandbox', signedTransactionInfo: signed }, ...overrides,
});
