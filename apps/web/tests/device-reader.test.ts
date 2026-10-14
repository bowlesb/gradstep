import { expect, it } from 'vitest';
import { decodeEvent, encodeEvent, type PrivateEvent, type SourcePaperReference } from '../src/lib/events';
import { generateBundle, keyRing, openEvent, sealEvent } from '../src/lib/wire';

const account = '11111111-2222-4333-8444-555555555555';
const device = 'aaaaaaaa-0000-4000-8000-000000000001';
const membership = 'bbbbbbbb-0000-4000-8000-000000000002';
const ref: SourcePaperReference = {format:'source-membership-v1',membershipID:membership,source:'arxiv',sourceID:'2305.18290',revision:3};
it('encodes source identities without inventing a server document and authenticates format two', async () => {
 const event: PrivateEvent = {kind:'note',entityID:membership,parents:[],documentID:membership,paperReference:ref,text:'a passage',
  anchor:{manifestSHA256:'a'.repeat(64),quote:'x^2',prefix:'',suffix:''}};
 const encoded = encodeEvent(event);
 expect(encoded.documentID).toBeUndefined(); expect(decodeEvent(encoded)).toEqual(event);
 const ring = await keyRing(generateBundle(account));
 const sealed = await sealEvent(encoded,membership,device,ring);
 expect(sealed.format).toBe(2);
 expect(decodeEvent(await openEvent(sealed,ring))).toEqual(event);
 await expect(openEvent({...sealed,format:1},ring)).rejects.toThrow();
 expect(() => decodeEvent({...encoded,documentID:membership})).toThrow();
 expect(() => decodeEvent({...encoded,paperReference:{...ref,revision:0}})).toThrow();
 expect(() => decodeEvent({...encoded,anchor:{...event.anchor,artifactID:membership}})).toThrow();
});
it('understands encrypted local PDF membership without file bytes or cloud document', async () => {
 const event: PrivateEvent = {kind:'local_paper',entityID:membership,parents:[],text:JSON.stringify({format:'device-pdf-membership-v1',title:'My PDF',pageCount:2,createdAt:10,archived:false,tags:[]})};
 const ring = await keyRing(generateBundle(account));
 const envelope = await sealEvent(encodeEvent(event),membership,device,ring);
 expect(envelope.format).toBe(2);
 expect(decodeEvent(await openEvent(envelope,ring)).documentID).toBeUndefined();
});
