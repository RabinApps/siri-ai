import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  // Site is served from the repo's GitHub Pages subpath
  // (https://rabinapps.github.io/siri-ai/). Build-time setting: change it if
  // the site moves to a custom domain root.
  base: '/siri-ai/',
  title: 'siri-ai',
  description:
    'Apple Intelligence and the real Siri AI app from your terminal. One Swift 6 binary — fully on-device, no API keys.',

  head: [['meta', { name: 'theme-color', content: '#ff5d7d' }]],

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'CLI Reference', link: '/cli/' },
      { text: 'Serve API', link: '/serve/' },
      { text: 'RabinApps.com', link: 'https://www.rabinapps.com' },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Embedding in a Swift app', link: '/guide/swift-app-integration' },
          { text: 'Code examples', link: '/guide/examples' },
          { text: 'Chat', link: '/guide/chat' },
          { text: 'Repository Q&A & Editing', link: '/guide/repo-editing' },
          { text: 'Fast typed decisions', link: '/guide/fast-decisions' },
          { text: 'Custom decision specs', link: '/guide/decision-specs' },
          { text: 'Permissions', link: '/guide/permissions' },
          { text: 'Testing & Fixtures', link: '/guide/testing' },
          { text: 'Release workflow', link: '/guide/release-workflow' },
        ],
      },
      {
        text: 'CLI Reference',
        items: [
          { text: 'Overview', link: '/cli/' },
          { text: 'status', link: '/cli/status' },
          { text: 'permission', link: '/cli/permission' },
          { text: 'ask', link: '/cli/ask' },
          { text: 'chat', link: '/cli/chat' },
          { text: 'serve', link: '/cli/serve' },
        ],
      },
      {
        text: 'Serve API',
        items: [
          { text: 'Overview + endpoint spec', link: '/serve/' },
        ],
      },
      {
        text: 'Project',
        items: [
          { text: 'Architecture', link: '/project/architecture' },
          { text: 'Privacy', link: '/project/privacy' },
          { text: 'Changelog', link: '/changelog' },
        ],
      },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/RabinApps/siri-ai' }],

    // Sponsor links render in the footer message (VitePress has no built-in
    // sponsor slot outside home layouts); FUNDING.yml keeps the same targets
    // for the repo-header Sponsor button.

    outline: { level: [2, 3], label: 'On this page' },

    search: {
      provider: 'local',
    },

    footer: {
      message:
        'Released under the MIT License · Sponsor: ' +
        '<a href="https://www.paypal.com/donate/?hosted_button_id=YEJ37WF4Q3HPC" target="_blank" rel="noopener">PayPal</a> · ' +
        '<a href="https://buymeacoffee.com/rabinapps" target="_blank" rel="noopener">Buy Me a Coffee</a>',
      copyright:
        'Copyright © 2026 <a href="https://www.rabinapps.com" target="_blank" rel="noopener">Rabin Apps LLC</a>',
    },
  },
})
