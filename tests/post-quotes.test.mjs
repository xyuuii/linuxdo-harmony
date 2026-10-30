import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const compiler = [process.env.DEVECO_TYPESCRIPT_PATH,
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js',
  '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript/lib/typescript.js'
].find(candidate => candidate && existsSync(candidate));
assert.ok(compiler, 'Use the existing DevEco TypeScript compiler.');
const ts = require(compiler);
const source = readFileSync(new URL('../app/entry/src/main/ets/components/RichPostContent.ets', import.meta.url), 'utf8');
const pure = source.slice(source.indexOf('export interface PostInline'), source.indexOf('@ComponentV2'));
const compiled = ts.transpileModule(pure, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
const module = { exports: {} };
new Function('module', 'exports', compiled)(module, module.exports);
const { parsePostContent, groupPostContent, postQuoteCanCollapse, visiblePostQuoteBlocks } = module.exports;
const bodyText = blocks => blocks.flatMap(block => block.runs.map(run => run.text)).join('');
const quote = (body, username = 'author', post = 7) =>
  `<aside class="quote" data-username="${username}" data-topic="42" data-post="${post}">` +
  '<div class="title"><div class="quote-controls"><svg><title>browser controls</title></svg></div>' +
  `<img class="avatar" src="/user_avatar/linux.do/${username}/20/avatar.png" width="20" height="20">` +
  `<a href="/t/topic/42/${post}">${username}:</a></div><blockquote>${body}</blockquote></aside>`;

test('a Discourse quote becomes one group with a compact author/avatar/floor header and multiple body paragraphs', () => {
  const blocks = parsePostContent(quote('<p>First quoted paragraph.</p><p>Second quoted paragraph.</p>') + '<p>Following reply.</p>');
  const groups = groupPostContent(blocks);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].quote, true);
  assert.equal(groups[0].header.username, 'author');
  assert.equal(groups[0].header.avatarUrl, 'https://linux.do/user_avatar/linux.do/author/20/avatar.png');
  assert.equal(groups[0].header.postNumber, 7);
  assert.equal(groups[0].header.href, 'https://linux.do/t/42/7');
  assert.deepEqual(groups[0].blocks.map(block => block.kind), ['paragraph', 'paragraph']);
  assert.equal(bodyText(groups[0].blocks), 'First quoted paragraph.Second quoted paragraph.');
  assert.equal(bodyText(groups[1].blocks), 'Following reply.');
  assert.equal(groups[1].quote, false);
  assert.ok(!bodyText(blocks).includes('author:'));
  assert.ok(!bodyText(blocks).includes('browser controls'));
});

test('quote avatars never enter the flat gallery while quoted body pictures, inline emoji and real links remain available', () => {
  const blocks = parsePostContent(quote('<p>Text <img class="emoji" src="/images/emoji/smile.png" alt=":smile:">' +
    '<a href="/t/topic/55/9">real link</a></p><img src="/uploads/body.png" width="690" height="400">') +
    '<img src="/uploads/outside.png" width="690" height="500">');
  // TopicPage's existing gallery consumes this flat kind=image view.
  const pictures = blocks.filter(block => block.kind === 'image');
  assert.deepEqual(pictures.map(block => block.url), ['https://linux.do/uploads/body.png', 'https://linux.do/uploads/outside.png']);
  assert.equal(pictures[0].quote, true);
  assert.equal(pictures[0].imageWidth, 690);
  const runs = blocks.flatMap(block => block.runs);
  assert.ok(runs.some(run => run.emojiUrl === 'https://linux.do/images/emoji/smile.png'));
  assert.ok(runs.some(run => run.href === 'https://linux.do/t/topic/55/9'));
  assert.equal(groupPostContent(blocks)[0].blocks.filter(block => block.kind === 'image').length, 1);
});

test('adjacent quotes stay separate and nested headers/body retain their real nesting inside the outer container', () => {
  const groups = groupPostContent(parsePostContent(quote('<p>Outer before.</p>' + quote('<p>Nested.</p>', 'nested', 9) +
    '<p>Outer after.</p>') + quote('<p>Independent.</p>', 'other', 10)));
  assert.equal(groups.length, 2);
  assert.notEqual(groups[0].key, groups[1].key);
  assert.equal(groups[0].header.username, 'author');
  const nested = groups[0].blocks.find(block => block.kind === 'quote_header');
  assert.equal(nested.quoteHeader.username, 'nested');
  assert.equal(nested.quoteLevel, 2);
  const paragraphs = groups[0].blocks.filter(block => block.kind === 'paragraph');
  assert.deepEqual(paragraphs.map(block => [bodyText([block]), block.quoteLevel]),
    [['Outer before.', 1], ['Nested.', 2], ['Outer after.', 1]]);
  assert.equal(groups[1].header.username, 'other');
  assert.equal(groups[1].header.postNumber, 10);
});

test('collapse keeps a reversible complete body, and long bare blockquotes receive an expansion control without truncating text', () => {
  const long = 'A complete long quotation. '.repeat(35);
  const group = groupPostContent(parsePostContent(`<blockquote><p>${long}</p><p>Last paragraph.</p></blockquote>`))[0];
  assert.equal(group.header, undefined);
  assert.equal(postQuoteCanCollapse(group), true);
  assert.deepEqual(visiblePostQuoteBlocks(group, true), []);
  assert.equal(bodyText(visiblePostQuoteBlocks(group, false)), long + 'Last paragraph.');
  assert.equal(bodyText(group.blocks), long + 'Last paragraph.');
  const short = groupPostContent(parsePostContent('<blockquote><p>Short.</p></blockquote>'))[0];
  assert.equal(postQuoteCanCollapse(short), false);
  assert.equal(bodyText(short.blocks), 'Short.');
});

test('malformed quote titles do not swallow their body and executable or foreign header destinations are never used', () => {
  const malformed = '<aside class="quote" data-username="author" data-topic="42" data-post="7">' +
    '<div class="title"><img class="avatar" src="javascript:evil"><script>hidden()</script>author:' +
    '<blockquote><p>Readable body.</p></blockquote></aside><p>Normal after.</p>';
  const groups = groupPostContent(parsePostContent(malformed));
  assert.equal(groups[0].header.username, 'author');
  assert.equal(groups[0].header.avatarUrl, '');
  assert.equal(bodyText(groups[0].blocks), 'Readable body.');
  assert.equal(bodyText(groups[1].blocks), 'Normal after.');
  for (const href of ['javascript:evil', 'file:///tmp/private', 'https://linux.do.evil.test/t/topic/42/7', 'https://u:p@linux.do/t/topic/42/7']) {
    const group = groupPostContent(parsePostContent('<aside class="quote"><div class="title">' +
      `<a href="${href}">author:</a></div><blockquote><p>Body.</p></blockquote></aside>`))[0];
    assert.equal(group.header.href, '', href);
    assert.equal(bodyText(group.blocks), 'Body.');
  }
});
