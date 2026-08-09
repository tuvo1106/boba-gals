import { BrowserRouter, Route, Routes, useParams } from 'react-router-dom'
import { BoardScreen } from './board/BoardScreen'
import { KdsScreen } from './kds/KdsScreen'
import { DashboardScreen } from './dashboard/DashboardScreen'
import { OrderingApp } from './order/OrderingApp'
import { OrderStatusScreen } from './order/OrderStatusScreen'

// One React codebase, one build (§9.3). Each surface is a route rather than a
// separate app: the kiosk and web ordering flows (§9.3), the KDS (§9.4), and
// the simulation dashboard (§10.6) join the board here as they land.
//
// `/order` and `/kiosk` render the same component. Kiosk mode is a runtime flag,
// not a fork (§9.3) — the route is where the flag is set, and `order/mode.ts` is
// the whole of what it changes.
function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/board" element={<BoardScreen />} />
        <Route path="/dashboard" element={<DashboardScreen />} />
        <Route path="/kds" element={<KdsScreen />} />
        <Route path="/order" element={<OrderingApp mode="web" />} />
        <Route path="/kiosk" element={<OrderingApp mode="kiosk" />} />
        <Route path="/order/:pickupCode" element={<OrderStatus />} />
        <Route path="*" element={<Placeholder />} />
      </Routes>
    </BrowserRouter>
  )
}

// Reachable by URL so a customer who closed the tab can get back to their order
// with nothing but the code from their receipt. The code is the whole
// credential (§13.1) and there is deliberately no account to sign in to (§9.3).
function OrderStatus() {
  const { pickupCode } = useParams()

  return <OrderStatusScreen pickupCode={(pickupCode ?? '').toUpperCase()} mode="web" />
}

function Placeholder() {
  return (
    <main className="min-h-screen bg-neutral-950 text-neutral-100 grid place-items-center">
      <div className="text-center">
        <h1 className="text-3xl font-semibold tracking-tight">Boba Gals</h1>
        <p className="mt-2 text-neutral-400">Ordering &amp; kitchen scheduling</p>
        <p className="mt-6 text-neutral-500">
          Order at <code className="text-neutral-300">/order</code>, board at{' '}
          <code className="text-neutral-300">/board</code>, simulation dashboard at{' '}
          <code className="text-neutral-300">/dashboard</code>.
        </p>
      </div>
    </main>
  )
}

export default App
