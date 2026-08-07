// Placeholder shell. The real surfaces — kiosk/web ordering (§9.3), KDS (§9.4),
// board (§9.5), and the simulation dashboard (§10.6) — arrive from build step 1
// onward. This exists so step 0 can prove the container, build, and test path.
function App() {
  return (
    <main className="min-h-screen bg-neutral-950 text-neutral-100 grid place-items-center">
      <div className="text-center">
        <h1 className="text-3xl font-semibold tracking-tight">Boba Gals</h1>
        <p className="mt-2 text-neutral-400">Ordering &amp; kitchen scheduling</p>
      </div>
    </main>
  )
}

export default App
