<script setup lang="ts">
import { computed } from 'vue'
import { useData } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import TerminalHero from './TerminalHero.vue'

const { Layout } = DefaultTheme
const { frontmatter } = useData()

// The animated terminal lives in the hero (under the tagline) on home only.
const isHome = computed(() => frontmatter.value.layout === 'home')
</script>

<template>
  <Layout>
    <template #home-hero-info-after>
      <TerminalHero v-if="isHome" />
    </template>
  </Layout>
</template>
