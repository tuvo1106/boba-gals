import '@testing-library/jest-dom/vitest'
import { afterAll, afterEach, beforeAll } from 'vitest'
import { server } from './server'

// `error` rather than `warn` on an unhandled request: a component that calls an
// endpoint no test declared is either a bug or an untested code path, and both
// deserve a failure rather than a line of output nobody reads.
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
