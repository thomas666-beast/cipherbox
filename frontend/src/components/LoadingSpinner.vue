<script setup>
defineProps({
  label: { type: String, default: 'loading...' },
})
</script>

<template>
  <div class="flex items-center justify-center gap-3 py-8 font-mono text-sm text-gray-500">
    <div class="flex gap-1">
      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" style="animation-delay: 0ms"></span>
      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" style="animation-delay: 150ms"></span>
      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" style="animation-delay: 300ms"></span>
    </div>
    <span>{{ label }}</span>
  </div>
</template>
