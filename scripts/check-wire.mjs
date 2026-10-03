#!/usr/bin/env node
// Fixed, public test keys and nonces. This file must never be used for user data.
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { encode, seal, open, eventAAD, recoveryKey, recoveryAAD, publicBytes, wrapDevice, unwrapDevice, sha256 } from '../tests/backend/wire-crypto.mjs';

const root=new URL('../',import.meta.url);
const account='11111111-2222-4333-8444-555555555555',device='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',event='12345678-abcd-4abc-8def-123456789abc';
const bytes=(start,length=32)=>Buffer.from(Array.from({length},(_,i)=>(start+i)&255));
const content=bytes(0x20),management=bytes(0x80),challenge=bytes(0x60),rawPrivate=bytes(0),code=bytes(0xb0).toString('hex');
const keys={accountID:account.toUpperCase(),epoch:1,contentKeys:{'1':content.toString('base64')},managementToken:management.toString('base64')};
const payload={kind:'message',entityID:'ABCDEF01-2345-4678-9ABC-DEF012345678',parents:['99999999-0000-4000-8000-111111111111'],conversationID:'CCCCCCCC-0000-4000-8000-AAAAAAAAAAAA',documentID:'DDDDDDDD-0000-4000-8000-BBBBBBBBBBBB',text:'Why does ∑ attention ≥ 0?\nA quote: "context"; slash /; café; 中文.',role:'user',status:'complete',anchor:{artifactID:'EEEEEEEE-0000-4000-8000-CCCCCCCCCCCC',quote:'∑ attention',prefix:'before ',suffix:' after',elementID:'section-2',page:3}};
const input={keys,payload,eventID:event,deviceID:device,challenge:challenge.toString('base64'),privateKey:rawPrivate.toString('base64'),recoveryCode:code,
  eventCiphertext:seal(content,encode(payload),eventAAD(account,event,device),bytes(0,12)).toString('base64'),
  recoveryPackage:seal(recoveryKey(code,account),encode(keys),recoveryAAD(account),bytes(0x10,12)).toString('base64'),
  deviceEnvelope:wrapDevice(keys,device,publicBytes(rawPrivate),challenge,bytes(0xe0),bytes(0x30,12)).toString('base64')};
const directory=new URL('apps/apple/ScienceReaderCore/Tests/ScienceReaderCoreTests/Fixtures/',root);
mkdirSync(directory,{recursive:true});
const fixture=new URL('envelopes-v1.json',directory),encoded=JSON.stringify(input,null,2)+'\n';
if(process.argv.includes('--write-fixture')) {writeFileSync(fixture,encoded); console.log('Recorded deterministic, public protocol fixture');}
else assert.equal(readFileSync(fixture,'utf8'),encoded,'Wire fixture changed; review the protocol before regenerating it');
const output=JSON.parse(execFileSync('swift',['run','--package-path',new URL('apps/apple/ScienceReaderCore',root).pathname,'ScienceReaderWireCheck'],{input:JSON.stringify(input),encoding:'utf8',timeout:120000,maxBuffer:1024*1024}));
const ciphertext=Buffer.from(output.eventCiphertext,'base64');
assert.deepEqual(open(content,ciphertext,eventAAD(account,event,device)),payload);
assert.deepEqual(open(recoveryKey(code,account),Buffer.from(output.recoveryPackage,'base64'),recoveryAAD(account)),keys);
assert.deepEqual(unwrapDevice(Buffer.from(output.deviceEnvelope,'base64'),account,device,1,rawPrivate,challenge),keys);
assert.equal(output.fingerprint,sha256(Buffer.concat([Buffer.from(`science-reader/enrollment/v1/${account}/${device}/`),publicBytes(rawPrivate),challenge])).toString('hex'));
assert.throws(()=>open(content,ciphertext,eventAAD('00000000-0000-4000-8000-000000000001',event,device)));
const damaged=Buffer.from(output.deviceEnvelope,'base64');damaged[damaged.length-1]^=1;
assert.throws(()=>unwrapDevice(damaged,account,device,1,rawPrivate,challenge));
console.log('PASS Node → Swift and Swift → Node event, recovery, device envelopes, Unicode/anchor payload, enrollment fingerprint, and identity/tamper rejection');
