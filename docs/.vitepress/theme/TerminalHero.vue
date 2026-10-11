<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue'

interface Line {
  type: 'comment' | 'cmd' | 'out'
  text: string
}

// Mirrors the real CLI surface: `status` output lines from SiriAICommand.swift,
// the `[✓] … granted — thank you!` / `All required permissions granted.` lines
// from PermissionCommand.swift, and the `Tools used:` stderr note from the
// ask agentic path.
const lines: Line[] = [
  { type: 'comment', text: '# diagnose your machine' },
  { type: 'cmd', text: 'siri-ai status' },
  { type: 'out', text: 'apple:  OK — Apple Intelligence on-device model available' },
  { type: 'out', text: 'window: 8192 tokens for repo-grounded context' },
  { type: 'out', text: 'siri:   OK — Siri AI app reachable via Accessibility' },
  { type: 'comment', text: '# grant Accessibility — polls until the switch flips' },
  { type: 'cmd', text: 'siri-ai permission' },
  { type: 'out', text: '[✓] Accessibility: granted — thank you!' },
  { type: 'out', text: 'All required permissions granted.' },
  { type: 'comment', text: '# grounded repo Q&A — tool usage noted on stderr' },
  { type: 'cmd', text: 'siri-ai ask "explain this repo" --repo . --tools' },
  { type: 'out', text: 'Tools used: list_files, read_file, search_files' },
  { type: 'comment', text: '# or expose it as an OpenAI-compatible server' },
  { type: 'cmd', text: 'siri-ai serve --port 11434' },
]

const rendered: { type: Line['type']; comment: string; prompt: string; body: string }[] =
  lines.map((line) => ({
    type: line.type,
    comment: line.type === 'comment' ? line.text : '',
    prompt: line.type === 'cmd' ? '$ ' : '',
    body: line.type === 'comment' ? '' : line.text,
  }))

const MS_PER_CHAR = 12

// SSR renders the full static script (no-JS, SEO, first paint). On mount
// (if motion is allowed) we clear it and animate from empty.
const animated = ref(false)
const typed = ref(0)

const totalChars = rendered.reduce(
  (n, l) => n + l.comment.length + l.prompt.length + l.body.length,
  0,
)

let timer: number | undefined

function cleanup() {
  if (timer) window.clearTimeout(timer)
  timer = undefined
}

function runAnimation() {
  typed.value = 0
  animated.value = true
  const tick = () => {
    typed.value += 1
    if (typed.value < totalChars) {
      timer = window.setTimeout(tick, MS_PER_CHAR)
    } else {
      cleanup()
    }
  }
  timer = window.setTimeout(tick, 500)
}

onMounted(() => {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
  runAnimation()
  mediaCheck()
})

// Stop animating if the viewport shrinks below hero-friendly width.
const media = ref<MediaQueryList | null>(null)
function mediaCheck() {
  media.value = window.matchMedia('(min-width: 768px)')
  if (!media.value.matches) {
    cleanup()
    animated.value = false
    typed.value = totalChars // show the full static script
  }
}

onBeforeUnmount(cleanup)

// Per-line visible slice of the flattened script.
function visible(index: number) {
  const line = rendered[index]
  if (!animated.value) {
    return { comment: line.comment, prompt: line.prompt, body: line.body, typing: false }
  }
  let start = 0
  for (let i = 0; i < index; i++) {
    start += rendered[i].comment.length + rendered[i].prompt.length + rendered[i].body.length
  }
  const n = typed.value - start
  if (n <= 0) return { comment: '', prompt: '', body: '', typing: false }
  const part = (s: string, take: number) => s.slice(0, Math.max(0, Math.min(take, s.length)))
  const comment = part(line.comment, n)
  const rest = n - line.comment.length
  const prompt = part(line.prompt, rest)
  const body = part(line.body, rest - line.prompt.length)
  const typing = n < line.comment.length + line.prompt.length + line.body.length
  return { comment, prompt, body, typing }
}
</script>

<template>
  <div class="terminal-hero" aria-label="siri-ai quick-start terminal session">
    <div class="title-bar">
      <span class="dot" style="background:#ff5f57" />
      <span class="dot" style="background:#febc2e" />
      <span class="dot" style="background:#28c840" />
      <span class="title">zsh — siri-ai</span>
    </div>
    <pre><template
      v-for="(line, i) in rendered"
      :key="i"
    ><span
      v-if="line.comment"
      class="comment"
    >{{ visible(i).comment }}{{ visible(i).typing ? '\u200b' : '' }}</span><template v-else><span class="prompt">{{ visible(i).prompt }}</span><span
      :class="line.type === 'out' ? 'out' : ''"
    >{{ visible(i).body }}</span></template><span
      v-if="visible(i).typing"
      class="cursor"
    />
</template><span
      v-if="!animated || typed >= totalChars"
      class="cursor idle-cursor"
    /></pre>
  </div>
</template>

<style scoped>
/* ALWAYS a dark terminal: the site is dark-only by design, and the terminal is
   the brand centerpiece — pin its own palette so any transient/forced light
   theme state can never flash a light terminal. These are plain hex values,
   intentionally NOT theme variables, scoped to .terminal-hero only. */
.terminal-hero,
.terminal-hero .title-bar {
  --vp-c-border: #45232f;
  --vp-c-bg-elv: #191118;
  --vp-c-bg-soft: #221218;
  --vp-c-text-2: #d0a9b8;
  --vp-c-text-3: #9e7984;
}

/* Colors bind to VitePress theme variables (overridden dark above, and the
   site jamais-boots light via Layout.vue). */
.terminal-hero {
  border: 1px solid var(--vp-c-border);
  border-radius: 10px;
  background: var(--vp-c-bg-elv);
  overflow: hidden;
  box-shadow: 0 12px 32px -12px rgba(0, 0, 0, 0.28);
  font-family: var(--vp-font-family-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 13.5px;
  line-height: 1.55;
  text-align: left;
}

.title-bar {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 9px 13px;
  border-bottom: 1px solid var(--vp-c-border);
  background: var(--vp-c-bg-soft);
}

.dot {
  width: 11px;
  height: 11px;
  border-radius: 50%;
  display: inline-block;
}

.title {
  margin-left: 6px;
  color: var(--vp-c-text-2);
  font-size: 12px;
}

pre {
  margin: 0;
  padding: 13px 16px;
  white-space: pre-wrap;
  word-break: break-word;
}

.prompt {
  color: var(--vp-c-brand-1, var(--vp-c-brand));
  font-weight: 600;
  user-select: none;
}

.comment {
  color: var(--vp-c-text-3);
}

.out {
  color: var(--vp-c-text-2);
}

.cursor {
  display: inline-block;
  width: 0.55em;
  height: 1.05em;
  vertical-align: text-bottom;
  background: var(--vp-c-brand-1, var(--vp-c-brand));
  border-radius: 1px;
  animation: terminal-blink 1s steps(1) infinite;
}

@keyframes terminal-blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0; }
}

@media (prefers-reduced-motion: reduce) {
  .cursor {
    animation: none;
  }
}
</style>
