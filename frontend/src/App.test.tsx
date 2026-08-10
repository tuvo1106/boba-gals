import { render, screen } from '@testing-library/react'
import App from './App'

// Queries by role and accessible name, per docs/testing.md — data-testid is a
// last resort. Written before there was anything to test, to prove the Vitest +
// RTL path worked end to end. The surfaces arrived; this one stays as the
// smoke test that the app mounts at all.
describe('App', () => {
  it('renders the shop name as a heading', () => {
    render(<App />)

    expect(screen.getByRole('heading', { name: 'Boba Gals' })).toBeInTheDocument()
  })
})
