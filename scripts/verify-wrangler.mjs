#!/usr/bin/env node
// Parser/help integration checks against EXISTING npm Wrangler installs only.
// All commands end in --help or use the non-authenticating --scopes-list handler.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = process.argv.slice(2);
let app;
const clis = [];
for (let i = 0; i < args.length; i += 2) {
  if (args[i] === '--app') app = path.resolve(args[i + 1]);
  else if (args[i] === '--cli') clis.push(path.resolve(args[i + 1]));
  else throw Error('Usage: node scripts/verify-wrangler.mjs --app APP_EXECUTABLE --cli WRANGLER_JS [--cli WRANGLER_JS ...]');
}
assert(app && clis.length, 'Supply a built app executable and existing npm Wrangler JavaScript entries. Nothing is installed.');
const root = mkdtempSync(path.join(os.tmpdir(), 'wrangler-bar-parser-'));
const isolatedHome = path.join(root, 'isolated-home');
mkdirSync(isolatedHome, { mode: 0o700 });
const log = path.join(root, 'discard.log');
symlinkSync(os.devNull, log);
const env = {
  HOME: isolatedHome, XDG_CONFIG_HOME: path.join(isolatedHome, '.config'), WRANGLER_HOME: path.join(isolatedHome, 'wrangler'),
  TMPDIR: root, PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
  CI: 'true', NO_COLOR: '1', WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG_PATH: log,
};
const run = (executable, arguments_, label) => {
  const result = spawnSync(executable, arguments_, { cwd: root, env, encoding: 'utf8', timeout: 20_000, maxBuffer: 512 * 1024 });
  assert(!result.error && result.signal === null, `${label} did not complete`);
  return { status: result.status, output: result.stdout + result.stderr };
};
try {
  const defaultPlan = run(app, ['--print-login-plan'], 'default app plan');
  const namedPlan = run(app, ['--print-login-plan', '--profile', 'parser-probe'], 'named app plan');
  assert.equal(defaultPlan.status, 0);
  assert.equal(namedPlan.status, 0);
  const defaultCommand = JSON.parse(defaultPlan.output);
  const namedCommand = JSON.parse(namedPlan.output);
  assert.deepEqual(defaultCommand, { mode: 'default-device', arguments: ['login', '--device'] });
  assert.deepEqual(namedCommand, { mode: 'named-profile-help', arguments: null });
  for (const cli of clis) {
    const invoke = (command, label) => run(process.execPath, [cli, ...command], label);
    const versionResult = invoke(['--version'], 'Wrangler version');
    assert.equal(versionResult.status, 0);
    const version = versionResult.output.match(/(?:^|\s)(4\.(\d+)\.\d+)(?:\s|$)/);
    assert(version, 'Expected an installed Wrangler 4.x version');
    const help = invoke(['login', '--help'], 'login help');
    assert.equal(help.status, 0);
    assert(help.output.includes('--scopes-list'), 'Refuse a parser probe without a non-authenticating scopes-list handler');
    const supported = Number(version[2]) >= 119;
    assert.equal(help.output.includes('--device'), supported, 'Version floor and real device flag must agree');
    // The appended scopes-list flag makes this a read-only parser/handler probe,
    // not a login attempt. It never reaches OAuth, even if flags are accepted.
    const device = invoke([...defaultCommand.arguments, '--scopes-list', '--browser=false'], 'default parser probe');
    if (!supported) {
      assert.notEqual(device.status, 0);
      assert(/unknown argument[^\n]*device/i.test(device.output));
      console.log(`Wrangler ${version[1]}: unsupported device version rejected; app policy blocks named login.`);
      continue;
    }
    assert.equal(device.status, 0);
    assert(/account:read|user:read/.test(device.output), 'Expected the static scope list');
    const rejected = invoke(['login', '--device', '--profile', 'parser-probe', '--scopes-list', '--browser=false'], 'named parser regression');
    assert.notEqual(rejected.status, 0);
    assert(/--profile cannot be used with the login command/.test(rejected.output));
    const namedHelp = invoke(['auth', 'create', 'parser-probe', '--help'], 'official named-profile help');
    assert.equal(namedHelp.status, 0);
    assert(namedHelp.output.includes('--browser') && namedHelp.output.includes('--callback-host'));
    assert(!namedHelp.output.includes('--device'), 'Review new named-device support before changing the disabled app path');
    console.log(`Wrangler ${version[1]}: default device parser passed; invalid named login rejected; official named help confirmed.`);
  }
  const credentialFiles = readdirSync(isolatedHome, { recursive: true }).filter(name => /\.(?:toml|enc)$/.test(name));
  assert.deepEqual(credentialFiles, [], 'Read-only probes must not create credential files');
  console.log('Parser checks passed in a separate empty home; no OAuth was started and no credential files were created.');
} finally { rmSync(root, { recursive: true, force: true }); }
