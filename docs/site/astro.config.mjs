import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://mosafi2.github.io/BlazeSeq',
  base: '/BlazeSeq',
  integrations: [
    starlight({
      title: 'BlazeSeq',
      description:
        'High-performance bioinformatics I/O for Mojo with zero-copy parsing and GPU-ready data flows.',
      sidebar: [
        {
          label: 'Introduction',
          items: [
            { label: 'Overview', link: '/' },
            { label: 'Quick Start', link: '/#quick-start' },
            { label: 'Access Modes', link: '/#access-modes' },
          ],
        },
        {
          label: 'User Guide',
          items: [{ label: 'Parser Workflows', link: '/#parser-workflows' }],
        },
        { label: 'API Reference', autogenerate: { directory: 'api' } },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/MoSafi2/BlazeSeq' },
      ],
    }),
  ],
  output: 'static',
});
