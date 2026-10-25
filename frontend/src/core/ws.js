export class ChatSocket {
  constructor(tokenFetcher) {
    this.tokenFetcher = tokenFetcher
    this.ws = null
    this.handlers = new Map()
    this.reconnectDelay = 1000
    this.maxDelay = 30000
    this.closedByUser = false
    this.pendingJoin = null
    this.outQueue = []
    this.isConnected = false
  }

  async connect() {
    if (this.closedByUser) return

    let token
    try {
      token = await this.tokenFetcher()
    } catch (e) {
      // If token fetch fails (e.g. server down), retry
      if (!this.closedByUser) {
        setTimeout(() => this.connect(), this.reconnectDelay)
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxDelay)
      }
      return
    }

    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    const url = `${proto}://${location.host}/chat?token=${encodeURIComponent(token)}`
    this.ws = new WebSocket(url)

    this.ws.onopen = () => {
      this.reconnectDelay = 1000
      this.isConnected = true
      
      // Re-join the room if we were in one
      if (this.pendingJoin) {
        this.ws.send(JSON.stringify(this.pendingJoin))
      }

      // Flush the offline queue
      while (this.outQueue.length) {
        const encoded = this.outQueue.shift()
        try { this.ws.send(encoded) } catch (e) { 
          this.outQueue.unshift(encoded)
          break 
        }
      }

      this._emit('open')
    }

    this.ws.onmessage = (evt) => {
      let msg
      try { msg = JSON.parse(evt.data) } catch (e) { return }
      const list = this.handlers.get(msg.type) || []
      for (const h of list.slice()) h(msg)
      const any = this.handlers.get('*') || []
      for (const h of any.slice()) h(msg)
    }

    this.ws.onclose = () => {
      this.isConnected = false
      this._emit('close')
      if (!this.closedByUser) {
        setTimeout(() => this.connect(), this.reconnectDelay)
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxDelay)
      }
    }

    this.ws.onerror = () => {
      this._emit('error')
    }
  }

  on(type, handler) {
    if (!this.handlers.has(type)) this.handlers.set(type, [])
    this.handlers.get(type).push(handler)
    return () => {
      const list = this.handlers.get(type) || []
      const idx = list.indexOf(handler)
      if (idx !== -1) list.splice(idx, 1)
    }
  }

  send(obj) {
    const encoded = JSON.stringify(obj)
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(encoded)
      return true
    }
    
    // If not connected, queue it
    this.outQueue.push(encoded)
    return false
  }

  joinRoom(roomId) {
    this.pendingJoin = { type: 'chat.join', room_id: roomId }
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(this.pendingJoin))
    }
  }

  close() {
    this.closedByUser = true
    if (this.ws) this.ws.close()
  }

  _emit(type, ...args) {
    const list = this.handlers.get(type) || []
    for (const h of list.slice()) h(...args)
  }
}
