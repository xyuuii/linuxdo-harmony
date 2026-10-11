import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js']
  .find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
function load(relative) {
  const source = readFileSync(fileURLToPath(new URL(relative, import.meta.url)), 'utf8');
  const module = { exports: {} };
  const compiled = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText;
  new Function('exports', 'require', 'module', compiled)(module.exports, require, module);
  return module.exports;
}
const auth = load('../app/entry/src/main/ets/services/AuthNavigation.ets');
const forum = load('../app/entry/src/main/ets/models/ForumModels.ets');

test('GitHub authentication and the original Linux.do callback navigate without losing query or POST flow', () => {
  assert.equal(auth.allowedLoginNavigation('https://github.com/login/oauth/authorize?client_id=fixture&state=fixture'), true);
  assert.equal(auth.allowedLoginNavigation('https://linux.do/auth/github/callback?code=fixture&state=fixture'), true);
  assert.equal(auth.allowedLoginNavigation('https://connect.linux.do/oauth2/authorize?state=fixture'), true);
});
test('Visible identity providers have explicit HTTPS origins, not suffix matching', () => {
  for (const origin of ['https://accounts.google.com', 'https://discord.com', 'https://appleid.apple.com']) {
    assert.equal(auth.allowedLoginNavigation(origin + '/oauth'), true);
  }
  for (const value of ['https://github.com.evil.test/login', 'https://evil.test/github.com',
    'https://github.com@evil.test/', 'https://evil.test@github.com/', 'https://github.com:444/',
    'http://github.com/', 'javascript:alert(1)', 'file:///tmp/secret', 'https://github.com\\@evil.test/']) {
    assert.equal(auth.allowedLoginNavigation(value), false, value);
  }
});
test('Authentication navigation never expands the native forum API origin', () => {
  assert.equal(auth.allowedLoginNavigation('https://github.com/login'), true);
  assert.equal(forum.safeForumUrl('https://github.com/login'), '');
  assert.equal(forum.safeForumUrl('/session/current.json'), 'https://linux.do/session/current.json');
});
test('Address labels show the actual origin without exposing OAuth parameters', () => {
  assert.equal(auth.loginOrigin('https://github.com:443/login?state=private&code=private'), 'https://github.com');
  assert.equal(auth.loginPageTitle('https://github.com/login'), 'GitHub 认证');
  assert.equal(auth.loginPageTitle('https://linux.do/auth/github/callback'), 'LINUX DO 登录与验证');
  assert.equal(auth.loginOrigin('about:blank'), '');
});
test('Empty popup documents are allowed only in an explicit window creation context', () => {
  assert.equal(auth.allowedLoginNavigation('about:blank'), false);
  assert.equal(auth.allowedLoginNavigation('about:blank', true), true);
  assert.equal(auth.allowedLoginNavigation('', true), true);
});
