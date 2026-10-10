import DefaultTheme from 'vitepress/theme'
import TerminalHero from './TerminalHero.vue'
import Layout from './Layout.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout,
  enhanceApp({ app }) {
    app.component('TerminalHero', TerminalHero)
  },
}
