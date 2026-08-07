import { setupServer } from 'msw/node'

/**
 * Mock at the network boundary, never by stubbing component internals
 * (docs/testing.md). A test that stubs `apiGet` passes when the URL, the
 * method, or the response shape is wrong; this one does not.
 *
 * Handlers are declared per test with `server.use(...)`, so each example states
 * the API behaviour it depends on.
 */
export const server = setupServer()
