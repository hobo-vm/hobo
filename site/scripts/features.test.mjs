// node --test site/scripts/*.test.mjs (make test): resolveLink decides every relative link on both the README
// and the site, and a wrong answer there is a silently broken link, not a build failure.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { resolveLink } from './features.mjs';

const from = 'docs/features/clones.md';
const targets = { page: (slug) => `/${slug}/`, repoFile: (path) => `repo:${path}` };

test('a link to another feature file goes to its page, keeping any anchor', () => {
  assert.equal(resolveLink(from, './snapshots.md', targets), '/snapshots/');
  assert.equal(resolveLink(from, './getting-inside.md#share-folders', targets), '/getting-inside/#share-folders');
});

test('a link to any other repo file goes to it by its path from the repo root', () => {
  assert.equal(resolveLink(from, '../images/linux-desktop.png', targets), 'repo:docs/images/linux-desktop.png');
  assert.equal(resolveLink(from, '../design.md#snapshots', targets), 'repo:docs/design.md#snapshots');
  assert.equal(resolveLink(from, '../../README.md', targets), 'repo:README.md');
});

test('a .md file outside docs/features is a repo file, not a page', () => {
  assert.equal(resolveLink('docs/site/getting-started.md', './index.mdx', targets), 'repo:docs/site/index.mdx');
  assert.equal(resolveLink(from, './sub/other.md', targets), 'repo:docs/features/sub/other.md');
});

test('absolute URLs, site paths and bare anchors stay as they are', () => {
  for (const target of ['https://example.com/a.md', 'mailto:x@example.com', '/snapshots/', '#ephemeral-vms']) {
    assert.equal(resolveLink(from, target, targets), target);
  }
});
