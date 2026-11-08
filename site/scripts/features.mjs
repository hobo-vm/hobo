// The feature files, docs/features/*.md, read for both the README (readme.mjs) and the site
// (astro.config.mjs). Each starts with frontmatter (title, description, sidebar.order), then the
// short part the README shows, then a `<!-- more -->` line, then the full guide.
import { readdirSync, readFileSync } from 'node:fs';
import { posix } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = fileURLToPath(new URL('../../', import.meta.url));
export const siteURL = 'https://hobo.gsquared.app';
export const repoURL = 'https://github.com/ggal625/hobo';
export const featuresDir = 'docs/features';
export const moreMarker = '<!-- more -->';

/** Every feature, in `sidebar.order` order. Throws on a file that breaks the format. */
export function loadFeatures() {
  const dir = posix.join(repoRoot, featuresDir);
  const features = readdirSync(dir)
    .filter((name) => name.endsWith('.md'))
    .map((name) => parseFeature(name, readFileSync(posix.join(dir, name), 'utf8')));
  const byOrder = new Map();
  for (const feature of features) {
    const other = byOrder.get(feature.order);
    if (other) throw new Error(`${other.file} and ${feature.file} both have sidebar order ${feature.order}`);
    byOrder.set(feature.order, feature);
  }
  return features.sort((a, b) => a.order - b.order);
}

function parseFeature(name, text) {
  const file = posix.join(featuresDir, name);
  const fail = (message) => { throw new Error(`${file}: ${message}`); };
  const match = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (!match) fail('no frontmatter');
  const frontmatter = match[1];
  const field = (pattern) => frontmatter.match(pattern)?.[1].trim();
  const title = unquote(field(/^title:(.*)$/m) ?? fail('no title'));
  const description = unquote(field(/^description:(.*)$/m) ?? fail('no description'));
  const order = Number(field(/^sidebar:\s*\n\s+order:(.*)$/m) ?? fail('no sidebar order'));
  if (!Number.isInteger(order)) fail('sidebar order must be a whole number');
  const body = text.slice(match[0].length);
  const parts = body.split(`\n${moreMarker}\n`);
  if (parts.length !== 2) fail(`needs exactly one "${moreMarker}" line, after the short part`);
  return { file, slug: name.replace(/\.md$/, ''), title, description, order, short: parts[0].trim() };
}

function unquote(value) {
  return /^(["']).*\1$/.test(value) ? value.slice(1, -1) : value;
}

/**
 * Where a relative link in `fromFile` (repo-relative) should point: `page(slug)` for another
 * feature file, `repoFile(path)` (`path` from the repo root) for anything else in the repo. Absolute
 * URLs and anchors stay as they are.
 */
export function resolveLink(fromFile, target, { page, repoFile }) {
  if (/^([a-z]+:|#|\/)/i.test(target)) return target;
  const [path, hash = ''] = target.split(/(?=#)/);
  const resolved = posix.normalize(posix.join(posix.dirname(fromFile), path));
  const feature = resolved.match(new RegExp(`^${featuresDir}/([^/]+)\\.md$`));
  return (feature ? page(feature[1]) : repoFile(resolved)) + hash;
}
