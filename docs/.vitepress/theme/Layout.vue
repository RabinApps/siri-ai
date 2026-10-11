<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useData } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import TerminalHero from './TerminalHero.vue'

const { Layout } = DefaultTheme
const { frontmatter, isDark } = useData()

// The animated terminal lives in the hero (under the tagline) on home only.
const isHome = computed(() => frontmatter.value.layout === 'home')

// Dark-only site: pin the theme to dark on mount. The appearance switcher is
// also hidden via CSS; anything the user toggled before (localStorage) is
// overridden to dark so the site never boots light.
onMounted(() => {
  isDark.value = true
  localStorage.setItem('vitepress-theme-appearance', 'dark')
})
</script>

<template>
  <Layout>
    <template #home-hero-info-after>
      <TerminalHero v-if="isHome" />
    </template>
  </Layout>
</template>
