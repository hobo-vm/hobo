import { posix } from 'node:path';
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
      generateId: ({ entry }) => posix.basename(entry).replace(/\.mdx?$/, ''),
    }),
    schema: docsSchema(),
  }),
};
