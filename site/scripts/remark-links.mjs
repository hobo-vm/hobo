// Rewrites relative links in docs/ pages for the site: ./snapshots.md becomes /snapshots/, and a
// link to another file in the repo (../design.md) goes to it on GitHub. The files keep links
// that work on GitHub, where they're also read.
import { posix } from 'node:path';
import { repoRoot, repoURL, resolveLink } from './features.mjs';

export function remarkLinks() {
  return (tree, file) => {
    const path = file.history[0];
    if (!path?.startsWith(repoRoot)) return;
    const fromFile = posix.relative(repoRoot, path);
    const visit = (node) => {
      if (node.type === 'link') {
        node.url = resolveLink(fromFile, node.url, { page: (slug) => `/${slug}/`, repoFile: (repoPath) => `${repoURL}/blob/main/${repoPath}` });
      }
      node.children?.forEach(visit);
    };
    visit(tree);
  };
}
