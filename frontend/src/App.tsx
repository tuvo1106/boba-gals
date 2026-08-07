import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { BoardScreen } from './board/BoardScreen'

// One React codebase, one build (§9.3). Each surface is a route rather than a
// separate app: the kiosk and web ordering flows (§9.3), the KDS (§9.4), and
// the simulation dashboard (§10.6) join the board here as they land.
function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/board" element={<BoardScreen />} />
        <Route path="*" element={<Placeholder />} />
      </Routes>
    </BrowserRouter>
  )
}

function Placeholder() {
  return (
    <main className="min-h-screen bg-neutral-950 text-neutral-100 grid place-items-center">
      <div className="text-center">
        <h1 className="text-3xl font-semibold tracking-tight">Boba Gals</h1>
        <p className="mt-2 text-neutral-400">Ordering &amp; kitchen scheduling</p>
        <p className="mt-6 text-neutral-500">
          The customer board is at <code className="text-neutral-300">/board</code>.
        </p>
      </div>
    </main>
  )
}

export default App
