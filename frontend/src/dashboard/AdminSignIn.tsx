import { useState } from 'react'

/**
 * Admin sign-in (§13.4). The only door to the dashboard, and the only screen
 * rendered until it is opened.
 *
 * **The error stays vague on purpose.** The server answers a wrong address and
 * a wrong password identically, so that the endpoint cannot be used to ask
 * "does this address have an account" — and a helpful "no account with that
 * email" here would undo that from the client side, for free. Whatever the
 * server says is what is shown.
 *
 * There is no signup, no password reset, and no "remember me": §13.4 is one
 * user created by seed or console, and every extra affordance here is another
 * unauthenticated endpoint on the surface that changes live scheduler
 * behaviour.
 */
export function AdminSignIn({
  onSignIn,
}: {
  onSignIn: (email: string, password: string) => Promise<void>
}) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await onSignIn(email, password)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Sign in failed')
      // Cleared on a failure, kept on the email. Retyping an address you got
      // right is annoying; a password field left populated after a rejection
      // invites tapping the button again unchanged.
      setPassword('')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center bg-neutral-950 text-neutral-100">
      <form onSubmit={submit} className="flex w-80 flex-col gap-4">
        <h1 className="font-mono text-sm tracking-widest text-neutral-500 uppercase">
          Simulation dashboard
        </h1>

        <label className="flex flex-col gap-1 font-mono text-xs text-neutral-500">
          email
          <input
            type="email" value={email} onChange={(e) => setEmail(e.target.value)}
            required aria-label="email" autoComplete="username"
            className="rounded border border-neutral-700 bg-transparent px-3 py-2 text-base text-neutral-100 focus:border-amber-500 focus:outline-none"
          />
        </label>

        <label className="flex flex-col gap-1 font-mono text-xs text-neutral-500">
          password
          <input
            type="password" value={password} onChange={(e) => setPassword(e.target.value)}
            required aria-label="password" autoComplete="current-password"
            className="rounded border border-neutral-700 bg-transparent px-3 py-2 text-base text-neutral-100 focus:border-amber-500 focus:outline-none"
          />
        </label>

        {error && <p role="alert" className="font-mono text-sm text-rose-400">{error}</p>}

        <button
          type="submit" disabled={busy}
          className="rounded bg-amber-600 py-2.5 font-semibold text-neutral-950 disabled:opacity-40 hover:bg-amber-500"
        >
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
    </main>
  )
}
