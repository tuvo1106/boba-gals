import { render, screen } from '@testing-library/react'
import App from './App'

// Queries by role and accessible name, per docs/testing.md — data-testid is a
// last resort. This spec exists to prove the Vitest + RTL path works end to end;
// the surfaces it will eventually cover arrive from build step 1.
describe('App', () => {
  it('renders the shop name as a heading', () => {
    render(<App />)

    expect(screen.getByRole('heading', { name: 'Boba Gals' })).toBeInTheDocument()
  })
})
