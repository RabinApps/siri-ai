import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  // The GitHub Pages custom subdomain serves this site at its root.
  base: '/',
  title: 'siri-ai',
  description:
    'Apple Intelligence and the real Siri AI app from your terminal. One Swift 6 binary — fully on-device, no API keys.',
  // Absolute deploy origin for og:image / og:url (there is no runtime origin
  // to read in static-site land; update if the site ever moves domains).
  socialBase: 'https://siri-ai.rabinapps.com',

  head: [
    ['meta', { name: 'theme-color', content: '#ff5d7d' }],
    // Branded share card (image lives in docs/public/, copied to the site root)
    ['meta', { property: 'og:image', content: 'https://siri-ai.rabinapps.com/og.png' }],
    ['meta', { property: 'og:image:width', content: '1200' }],
    ['meta', { property: 'og:image:height', content: '630' }],
    ['meta', { property: 'og:image:alt', content: 'siri-ai — Apple Intelligence and the Siri AI app in your terminal' }],
    ['meta', { property: 'og:site_name', content: 'siri-ai' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:image', content: 'https://siri-ai.rabinapps.com/og.png' }],
  ],

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
          { text: 'Agent skills', link: '/guide/agent-skills' },
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

  // Per-page Open Graph URL/title/description: VitePress hoists each page's
  // frontmatter title + description into <head> automatically, but og:url,
  // og:title and og:description need an origin-qualified absolute URL, which
  // the static build can't derive — so stamp them at build time.
  async transformHead({ pageData }) {
    const base = 'https://siri-ai.rabinapps.com'
    // Directory-style URLs — what the site actually serves and what crawlers
    // expect (e.g. guide/foo.md → /guide/foo/, index.md → /).
    const dir = String(pageData.relativePath)
      .replace(/index\.md$/, '')
      .replace(/\.md$/, '/')
    const url = dir === '' ? base + '/' : base + '/' + dir
    // Home has no frontmatter title; fall back to the site brand + tagline.
    const title = pageData.title || 'siri-ai — Apple Intelligence & Siri AI in your terminal'
    return [
      ['meta', { property: 'og:url', content: url }],
      ['meta', { property: 'og:title', content: title }],
      ['meta', { property: 'og:description', content: pageData.description }],
      ['meta', { name: 'twitter:title', content: title }],
      ['meta', { name: 'twitter:description', content: pageData.description }],
    ]
  },
})
