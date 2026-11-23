// The hobo.gsquared.app site: docs/site/*.{md,mdx} (the home and getting-started pages) and a page
// per docs/features/*.md, in the features' sidebar order. Cloudflare Workers Builds deploys it on
// each push to main.
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import { defineConfig } from 'astro/config';
import { loadFeatures, repoURL, siteURL } from './scripts/features.mjs';
import { remarkLinks } from './scripts/remark-links.mjs';

export default defineConfig({
  site: siteURL,
  // remark, not Astro's default Sätteri, for the plugin that rewrites links between files.
  markdown: { processor: unified({ remarkPlugins: [remarkLinks] }) },
  // The content lives in ../docs, outside this project.
  vite: { server: { fs: { allow: ['..'] } } },
  integrations: [
    starlight({
      title: 'Hobo',
      logo: { light: '../assets/logo-light.svg', dark: '../assets/logo-dark.svg', replacesTitle: true },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: repoURL }],
      sidebar: [
        { label: 'Getting started', link: '/getting-started/' },
        { label: 'Features', items: loadFeatures().map((feature) => ({ label: feature.title, link: `/${feature.slug}/` })) },
      ],
    }),
  ],
});
