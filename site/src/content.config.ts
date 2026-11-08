import { docsSchema } from '@astrojs/starlight/schema';
import { glob } from 'astro/loaders';
import { defineCollection } from 'astro:content';

// Every page comes from the repo's docs/ directory, named by its file: docs/features/snapshots.md
// is /snapshots/, and docs/site/index.mdx the home page. docs/design.md isn't published.
export const collections = {
  docs: defineCollection({
    loader: glob({
      base: '../docs',
      pattern: ['features/*.md', 'site/*.{md,mdx}'],
      generateId: ({ entry }) => posixBasename(entry).replace(/\.mdx?$/, ''),
    }),
    schema: docsSchema(),
  }),
};

function posixBasename(path: string) {
  return path.slice(path.lastIndexOf('/') + 1);
}
