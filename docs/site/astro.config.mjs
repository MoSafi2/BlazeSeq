import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://mosafi2.github.io/BlazeSeq',
  base: '/BlazeSeq',
  integrations: [
    starlight({
      title: 'BlazeSeq',
      description: 'Fast FASTQ parsing and GPU-accelerated sequencing utilities in Mojo.',
      sidebar: [
        { label: 'Introduction', link: '/' },
        { label: 'API Reference', autogenerate: { directory: 'api' } },
      ],
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/MoSafi2/BlazeSeq' },
      ],
    }),
  ],
  output: 'static',
});
