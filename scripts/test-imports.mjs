#!/usr/bin/env node
// Explicit, unpaid import acceptance gate. Reuse evidence only for identical import code, fixtures and toolchain.
import {createHash} from 'node:crypto';
import {spawn, execFileSync} from 'node:child_process';
import {readFileSync, writeFileSync, mkdirSync, existsSync, statSync, createWriteStream} from 'node:fs';
import {fileURLToPath} from 'node:url';
const root=fileURLToPath(new URL('../',import.meta.url)); process.chdir(root);
const mode=process.argv[2]??'run';
if(!['run','gate'].includes(mode)||process.argv.length>3)throw Error('Usage: node scripts/test-imports.mjs run|gate');
const folder='.artifacts/import-acceptance',reportPath=folder+'/latest.json'; mkdirSync(folder,{recursive:true});
const cases=[...[
 'testOfflineImportDownloadsValidatesEncryptsAndReopensWithNoNetwork',
 'testOfflineImportFailureDoesNotLoopAndExplicitRetrySucceeds',
 'testOfflineImportCancellationDoesNotPublishAndCanBeRetried',
 'testOfflineImportAbsentHTMLDownloadsAndReopensPDFWithoutUpload',
 'testOfflineReportedPaperRegressionsThroughNativeLibrary',
 'testImportTableRowsReserveTheSameHeightBeforeMetadataAndWhileAdding',
 'testImportTableRowsKeepTheReadyHeightWithTheProgressColumnHidden',
 'testAFailedImportsRetryFitsItsTitlesSecondLine',
 'testLocalPDFFileAddsARealLibraryItemAndRejectsDamagedInput',
].map(c=>'ScienceReaderTests/LibraryModelTests/'+c),
 'ScienceReaderTests/AuthenticationBackendTests/testDeletedRemoteSessionRetiresCachedCredentialsInsteadOfRetryingForever',
 'ScienceReaderTests/AuthenticationBackendTests/testRefreshTransientFailuresKeepOfflineIdentityAndCanRecover',
 'ScienceReaderTests/AuthenticationBackendTests/testClosedAccountWithUnexpiredTokenInvalidatesOnlyForExactAuthRejection',
 'ScienceReaderTests/AuthenticationModelTests/testRemoteDeletionRetiresVisibleAccountAndPreservesLocalFilesAndKeys',
 'ScienceReaderTests/ChatTransportTests/testRejectedChatSessionClearsAuthorityBeforeTheReaderCanTryAnotherCloudAction',
 'ScienceReaderUITests/AuthenticationWorkflowTests/testDeletedSessionAtLaunchReturnsToSignInAndStaysSignedOutAfterRestart',
 'ScienceReaderUITests/AuthenticationWorkflowTests/testAppleAndGoogleInvitationRefusalsStayVisibleAfterReturning',
 'ScienceReaderTests/LibraryTransportTests/testSourceKeywordEditSurvivesRestartAndUsesTheRealV5Transport',
];
function fingerprint(){
 const files=execFileSync('git',['ls-files','--cached','--others','--exclude-standard','-z'],{encoding:'utf8'}).split('\0')
  .filter(p=>p&&(/^(supabase\/functions\/_shared\/reader\/|tests\/fixtures\/reader|apps\/apple\/ScienceReaderCore\/Sources\/|apps\/apple\/ScienceReader\/Resources\/arxiv-|apps\/apple\/ScienceReader\/Services\/(Arxiv|DevicePDF|PaperAdding|PDFUpload|Library|SourceMetadata)|apps\/apple\/ScienceReader\/Views\/(Library|Import|PaperTable)|apps\/apple\/ScienceReaderTests\/LibraryModelTests.swift)/.test(p)
   ||['apps/apple/ScienceReader/ReaderModel.swift','apps/apple/ScienceReader/Views/RootView.swift','apps/apple/project.yml','scripts/test-imports.mjs','scripts/build-arxiv-compiler.mjs','tests/corpus/import-regressions.json','package-lock.json'].includes(p)
   ||/^apps\/apple\/ScienceReader\/Services\/(BackendClient|AuthenticationBackend|AuthenticationCoordinator|AuthenticationWorkflowFixture)\.swift$/.test(p)
   ||/^apps\/apple\/ScienceReader(?:UI)?Tests\/(AuthenticationBackendTests|AuthenticationModelTests|AuthenticationWorkflowTests|ChatTransportTests|LibraryServiceTests)\.swift$/.test(p)))
  .filter(p=>existsSync(p)&&statSync(p).isFile()).sort();
 const hash=createHash('sha256');
 hash.update(execFileSync('xcodebuild',['-version']));
 for(const p of files){hash.update(p+'\0');hash.update(readFileSync(p));}
 return hash.digest('hex');
}
const before=fingerprint();
// Missing/changed corpus is a failure before the Simulator starts, never an XCTest skip.
for(const paper of JSON.parse(readFileSync('tests/corpus/import-regressions.json')).cases)for(const input of paper.responses){
 const path='.artifacts/import-corpus/'+input.sha256;
 if(!/^[a-f0-9]{64}$/.test(input.sha256)||!existsSync(path)||statSync(path).size!==input.bytes
   ||createHash('sha256').update(readFileSync(path)).digest('hex')!==input.sha256)
  throw Error('Missing or changed import corpus. Run node scripts/fetch-import-regressions.mjs --on-this-device.');
}
if(mode==='gate'){
 const report=existsSync(reportPath)?JSON.parse(readFileSync(reportPath)):null;
 if(!report?.ok||report.fingerprint!==before||report.passed!==cases.length||report.skipped!==0
   ||!existsSync(report.resultBundle))throw Error('Import acceptance evidence is missing, failed, or stale. Run npm run test:imports before uploading.');
 console.log(`Import gate: ${report.passed} passed, none skipped; matching source (${report.finishedAt}).`);
 process.exit(0);
}
const stamp=new Date().toISOString().replace(/[:.]/g,'-'),log=`${folder}/${stamp}.log`,resultBundle=`${folder}/${stamp}.xcresult`;
const args=['test','-project','apps/apple/ScienceReader.xcodeproj','-scheme','ScienceReader',
 '-destination','platform=iOS Simulator,name=iPhone 17 Pro','-derivedDataPath','.artifacts/reader-integration-build',
 '-parallel-testing-enabled','NO','-resultBundlePath',resultBundle,
 'SWIFT_OPTIMIZATION_LEVEL=-O','SWIFT_COMPILATION_MODE=wholemodule',
 ...cases.map(c=>'-only-testing:'+c)];
console.log(`Import acceptance: release optimization, no provider calls; ${log}`);
const output=createWriteStream(log);
const exitCode=await new Promise(resolve=>{
 const child=spawn('xcodebuild',args,{stdio:['ignore','pipe','pipe']});
 child.stdout.pipe(output,{end:false});child.stderr.pipe(output,{end:false});
 child.on('error',e=>{output.write(String(e));resolve(1);});child.on('close',code=>resolve(code??1));
});
await new Promise(resolve=>output.end(resolve));
let summary=null;
try{summary=JSON.parse(execFileSync('xcrun',['xcresulttool','get','test-results','summary','--path',resultBundle],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));}catch{}
const ok=exitCode===0&&summary?.passedTests===cases.length&&summary.failedTests===0&&summary.skippedTests===0&&fingerprint()===before;
const report={ok,fingerprint:before,finishedAt:new Date().toISOString(),cases,log,resultBundle,exitCode,
 optimization:'-O',compilationMode:'wholemodule',passed:summary?.passedTests??0,failed:summary?.failedTests??0,skipped:summary?.skippedTests??0,
 devices:summary?.devicesAndConfigurations??[]};
writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');
console.log(`Import acceptance ${ok?'passed':'FAILED'}: ${report.passed} passed, ${report.failed} failed, ${report.skipped} skipped.`);
if(!ok)console.error(`Inspect ${log}; a successful build or zero selected tests is not acceptance.`);
process.exitCode=ok?0:1;
