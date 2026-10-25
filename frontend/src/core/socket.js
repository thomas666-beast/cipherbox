import { ChatSocket } from './ws'
import api from './api'

let instance = null

async function fetchWsToken() {
  const res = await api.get('/ws-token')
  return res.data.token
}

export async function getSocket() {
  if (instance && !instance.closedByUser) return instance
  instance = new ChatSocket(fetchWsToken)
  await instance.connect()
  return instance
}

export function closeSocket() {
  if (instance) instance.close()
  instance = null
}
