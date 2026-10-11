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

  head: [['meta', { name: 'theme-color', content: '#5f67ee' }]],

  themeConfig: {
    nav: [
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'CLI Reference', link: '/cli/' },
      { text: 'Serve API', link: '/serve/' },
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
          { text: 'Overview', link: '/serve/' },
          { text: 'Chat Completions', link: '/serve/chat-completions' },
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

    outline: { level: [2, 3], label: 'On this page' },

    search: {
      provider: 'local',
    },

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © 2026 Rabin Apps LLC',
    },
  },
})
