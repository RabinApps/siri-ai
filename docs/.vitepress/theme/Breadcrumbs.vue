<script setup lang="ts">
import { computed } from 'vue'
import { withBase } from 'vitepress'
import { useData } from 'vitepress'

// Breadcrumbs for the current page: resolves the page's position in
// themeConfig.sidebar (group label › page title) so the trail always matches
// the navigation definition in config.ts — no frontmatter bookkeeping needed.
// Home (layout: home) renders nothing.
const { theme, frontmatter, page } = useData()
const { isActive } = theme.value

const crumbs = computed(() => {
  if (frontmatter.value.layout === 'home') return []
  const url = page.value.relativePath
  const out: { label: string; link: string | null }[] = []
  for (const group of theme.value.sidebar || []) {
    for (const item of group.items || []) {
      if (item.link && url === String(item.link).replace(/^\//, '')) {
        out.push({ label: group.text, link: null })
        out.push({ label: item.text, link: withBase(item.link) })
        return out
      }
    }
  }
  // Pages not in the sidebar (e.g. /changelog mirror): single crumb from title.
  if (page.value.title) out.push({ label: page.value.title, link: null })
  return out
})
</script>

<template>
  <nav v-if="crumbs.length" class="vp-doc-breadcrumbs" aria-label="Breadcrumb">
    <template v-for="(c, i) in crumbs" :key="i">
      <span v-if="i > 0" class="sep" aria-hidden="true">/</span>
      <a v-if="c.link" :href="c.link">{{ c.label }}</a>
      <span v-else class="current">{{ c.label }}</span>
    </template>
  </nav>
</template>

<style scoped>
.vp-doc-breadcrumbs {
  max-width: 688px;
  margin: 0 auto;
  padding: 10px 24px 0;
  font-size: 13.5px;
  color: var(--vp-c-text-3);
}
.vp-doc-breadcrumbs a {
  color: var(--vp-c-brand-1);
}
.vp-doc-breadcrumbs .sep {
  margin: 0 7px;
  opacity: 0.55;
}
.vp-doc-breadcrumbs .current {
  color: var(--vp-c-text-2);
}
@media (max-width: 767px) {
  .vp-doc-breadcrumbs {
    padding-top: 4px;
  }
}
</style>
