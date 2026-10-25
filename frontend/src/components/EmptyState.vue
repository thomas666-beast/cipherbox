<script setup>
defineProps({
  title: { type: String, default: 'nothing here' },
  hint: { type: String, default: '' },
})
</script>

<template>
  <div class="text-center py-10 font-mono">
    <div class="text-gray-500 text-sm">
      <span class="text-emerald-400">&gt;</span> {{ title }}
    </div>
    <div v-if="hint" class="text-xs text-gray-600 mt-1">
      // {{ hint }}
    </div>
    <slot />
  </div>
</template>
