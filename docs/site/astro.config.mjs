import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://MoSafi2.github.io',
  base: '/BlazeSeq',
  integrations: [
    starlight({
      title: 'BlazeSeq',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/MoSafi2/BlazeSeq' },
      ],
      sidebar: [
        { label: 'Home', link: '/' },
        { label: 'API Reference', autogenerate: { directory: 'api' } },
      ],
    }),
  ],
});
