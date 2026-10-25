<script setup>
defineProps({
  message: { type: String, required: true },
})
</script>

<template>
  <div class="bg-red-500/10 border border-red-500/30 text-red-400 px-4 py-2.5 rounded-md mb-4 font-mono text-sm">
    <span class="text-red-500 font-bold">✗</span> {{ message }}
  </div>
</template>
