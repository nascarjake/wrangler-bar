#!/usr/bin/env node
// Existing official Wrangler only. Help, static scopes, and missing-profile probes never start OAuth.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const args=process.argv.slice(2);let app;const clis=[];
for(let i=0;i<args.length;i+=2){
 if(args[i]==='--app')app=path.resolve(args[i+1]);
 else if(args[i]==='--cli')clis.push(path.resolve(args[i+1]));
 else throw Error('Use --app APP_EXECUTABLE --cli WRANGLER_JS [--cli WRANGLER_JS ...]');
}
assert(app&&clis.length,'Supply a built app and existing npm Wrangler entries. Nothing is installed.');
const root=mkdtempSync(path.join(os.tmpdir(),'wrangler-bar-profile-parser-'));
const isolatedHome=path.join(root,'empty-home');mkdirSync(isolatedHome,{mode:0o700});
const log=path.join(root,'discard.log');symlinkSync(os.devNull,log);
const env={HOME:isolatedHome,XDG_CONFIG_HOME:path.join(isolatedHome,'.config'),WRANGLER_HOME:path.join(isolatedHome,'wrangler'),TMPDIR:root,PATH:`${path.dirname(process.execPath)}:/usr/bin:/bin`,CI:'true',NO_COLOR:'1',WRANGLER_SEND_METRICS:'false',WRANGLER_SEND_ERROR_REPORTS:'false',WRANGLER_LOG_PATH:log};
function run(executable,argv,label,extra={}){
 const r=spawnSync(executable,argv,{cwd:root,env:{...env,...extra},encoding:'utf8',timeout:20000,maxBuffer:512*1024});
 assert(!r.error&&r.signal===null,label+' did not finish');return {status:r.status,output:r.stdout+r.stderr};
}
try{
 const plan=name=>JSON.parse(run(app,['--print-login-plan','--profile',name],'app policy').output);
 const defaultPlan=plan('default'),namedPlan=plan('parser-probe');
 assert.deepEqual(defaultPlan,{profile:'default',arguments:['login','--device','--browser=true']});
 assert.deepEqual(namedPlan,{profile:'parser-probe',arguments:['auth','create','parser-probe','--browser=true']});
 assert.equal(plan('invalid;profile').arguments,null);
 for(const cli of clis){
  const invoke=(argv,label,extra)=>run(process.execPath,[cli,...argv],label,extra);
  const vr=invoke(['--version'],'version');assert.equal(vr.status,0);
  const version=vr.output.match(/(?:^|\s)(4\.(\d+)\.\d+)(?:\s|$)/);assert(version,'Expected Wrangler 4.x');
  if(Number(version[2])<160){console.log(`Wrangler ${version[1]}: below the profile-monitoring minimum; not used by 0.2.0.`);continue}
  const loginHelp=invoke(['login','--help'],'default help');
  assert.equal(loginHelp.status,0);assert(loginHelp.output.includes('--device')&&loginHelp.output.includes('--scopes-list'));
  const staticDefault=invoke([...defaultPlan.arguments.map(a=>a==='--browser=true'?'--browser=false':a),'--scopes-list'],'static default parser');
  assert.equal(staticDefault.status,0);assert(/account:read|user:read/.test(staticDefault.output));
  const namedHelp=invoke([...namedPlan.arguments,'--help'],'named help');
  assert.equal(namedHelp.status,0);assert(namedHelp.output.includes('--browser')&&namedHelp.output.includes('--callback-host'));
  assert(!namedHelp.output.includes('--device'));
  // The inspected handler validates names BEFORE entering OAuth. Invalid names cannot start a login.
  const invalidNamed=invoke(['auth','create','invalid;profile','--browser=false'],'invalid named parser');
  assert.notEqual(invalidNamed.status,0);assert(invalidNamed.output.includes('Invalid profile name'));
  const selector=invoke(['whoami','--json'],'explicit selector',{CLOUDFLARE_AUTH_PROFILE:'invalid;selector'});
  assert.notEqual(selector.status,0);assert(selector.output.includes('Invalid profile name'));
  for(const name of ['registered_expired_fixture','different_missing_profile','default']){
   const identity=invoke(['whoami','--json'],'empty-home identity',{CLOUDFLARE_AUTH_PROFILE:name});
   assert.notEqual(identity.status,0);assert(/"loggedIn"\s*:\s*false/.test(identity.output));
   assert(!identity.output.includes('Attempting to login'));
  }
  console.log(`Wrangler ${version[1]}: exact default/named plans, browser/callback help, strict names, explicit profile selection and unauthenticated status passed.`);
 }
 assert.deepEqual(readdirSync(isolatedHome,{recursive:true}).filter(x=>/\.(toml|enc)$/.test(x)),[]);
 console.log('Real CLI checks passed in an empty home; no OAuth, real profile query, credential file or package installation.');
}finally{rmSync(root,{recursive:true,force:true})}
