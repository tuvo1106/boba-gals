import { createConsumer, type Consumer, type Subscription } from '@rails/actioncable'

let consumer: Consumer | null = null

/**
 * One consumer per tab, created lazily.
 *
 * ActionCable multiplexes every subscription over a single websocket, so a
 * second consumer would open a second connection to the same server for no
 * benefit — and on the board, which runs unattended for a whole shift, leaked
 * connections are the failure that shows up at hour six rather than minute one.
 */
export function getConsumer(): Consumer {
  consumer ??= createConsumer('/cable')
  return consumer
}

interface SubscribeOptions<T> {
  channel: string
  params?: Record<string, unknown>
  onReceived: (data: T) => void
  onConnected?: () => void
  onDisconnected?: () => void
}

/**
 * Subscribe to a channel, returning an unsubscribe function suitable for a
 * `useEffect` cleanup.
 */
export function subscribe<T>({
  channel,
  params = {},
  onReceived,
  onConnected,
  onDisconnected,
}: SubscribeOptions<T>): () => void {
  const subscription: Subscription = getConsumer().subscriptions.create(
    { channel, ...params },
    {
      received: (data: unknown) => onReceived(data as T),
      connected: () => onConnected?.(),
      disconnected: () => onDisconnected?.(),
    },
  )

  return () => subscription.unsubscribe()
}
