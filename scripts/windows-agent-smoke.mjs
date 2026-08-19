import { spawn } from 'node:child_process'
import { existsSync, mkdirSync } from 'node:fs'
import { createServer } from 'node:http'
import { join, resolve } from 'node:path'

const [runtimeArgument, workspaceArgument] = process.argv.slice(2)
if (runtimeArgument === undefined || workspaceArgument === undefined) {
  throw new Error('usage: node windows-agent-smoke.mjs <runtime-directory> <workspace>')
}

const runtimeDirectory = resolve(runtimeArgument)
const workspace = resolve(workspaceArgument)
const nodePath = join(runtimeDirectory, 'node.exe')
const entryPath = join(
  runtimeDirectory,
  'node',
  'node_modules',
  '@deepseek-ai',
  'dsh-sdk-jsonrpc-demo',
  'lib',
  'packaged-bin.js',
)
const configPath = join(runtimeDirectory, 'DesktopPetAgent.cordis.yml')
const sessionRoot = join(workspace, 'sessions')
const skillRoot = join(workspace, '.desktop-pet', 'skills')

for (const requiredPath of [nodePath, entryPath, configPath]) {
  if (!existsSync(requiredPath)) throw new Error(`missing packaged Agent file: ${requiredPath}`)
}
mkdirSync(sessionRoot, { recursive: true })
mkdirSync(skillRoot, { recursive: true })

const placeholderKey = 'desktop-pet-build-smoke-placeholder-not-a-real-key'
let mockRequestCount = 0
let mockAuthorizationValid = true
const mockServer = createServer((request, response) => {
  let body = ''
  request.setEncoding('utf8')
  request.on('data', chunk => { body += chunk })
  request.on('end', () => {
    mockRequestCount += 1
    mockAuthorizationValid &&= request.headers.authorization === `Bearer ${placeholderKey}`
    if (request.url !== '/chat/completions') {
      response.writeHead(404).end()
      return
    }
    try {
      JSON.parse(body)
    } catch {
      response.writeHead(400).end()
      return
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    const events = [
      '{"choices":[{"delta":{"role":"assistant","content":null,"reasoning_content":""}}]}',
      '{"choices":[{"delta":{"content":"smoke-ok"}}]}',
      '{"choices":[{"delta":{"content":""},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}',
      '[DONE]',
    ]
    response.end(events.map(event => `data: ${event}\n\n`).join(''))
  })
})
await new Promise((resolveListen, rejectListen) => {
  mockServer.once('error', rejectListen)
  mockServer.listen(0, '127.0.0.1', resolveListen)
})
const mockAddress = mockServer.address()
if (mockAddress === null || typeof mockAddress === 'string') {
  throw new Error('could not determine the local DeepSeek smoke-test endpoint')
}

// The prompt goes only to the loopback mock above. This validates the complete
// JSON-RPC prompt path without placing a real API key in source, CI, or output.
const environment = {
  ...process.env,
  DEEPSEEK_API_KEY: placeholderKey,
  DEEPSEEK_BASE_URL: `http://127.0.0.1:${mockAddress.port}`,
  DSH_CORDIS_CONFIG: configPath,
  DSH_CWD: workspace,
  DSH_SESSION_ROOT: sessionRoot,
  DSH_SKILL_DIR: skillRoot,
  DSH_SYSTEM_PROMPT: 'DesktopPet packaged Agent initialization smoke test.',
  DSH_TELEMETRY_MODE: 'DISABLED',
  DSH_PLUGIN_SKILLS: '1',
  DSH_PLUGIN_TODO: '1',
  DSH_PLUGIN_GOALS: '0',
  DSH_PLUGIN_WEB_SEARCH: '0',
}

const child = spawn(nodePath, [entryPath], {
  cwd: workspace,
  env: environment,
  stdio: ['pipe', 'pipe', 'pipe'],
  windowsHide: true,
})

let stdoutBuffer = ''
let stderr = ''
let initialized = false
let pluginSnapshotReceived = false
let promptCompleted = false
let settled = false

function fail(message) {
  if (settled) return
  settled = true
  clearTimeout(timeout)
  child.kill()
  mockServer.close()
  const detail = stderr.trim()
  process.stderr.write(`${message}${detail === '' ? '' : `\nAgent stderr:\n${detail}`}\n`)
  process.exitCode = 1
}

function handleLine(line) {
  if (line.trim() === '') return
  let frame
  try {
    frame = JSON.parse(line)
  } catch {
    fail(`Packaged Agent returned invalid JSON-RPC: ${line}`)
    return
  }
  if (frame.id === 'desktop-pet-build-smoke-initialize') {
    if (frame.error !== undefined) {
      fail(`Packaged Agent initialization failed: ${JSON.stringify(frame.error)}`)
      return
    }
    initialized = true
    child.stdin.write(`${JSON.stringify({
      jsonrpc: '2.0',
      id: 'desktop-pet-build-smoke-plugins',
      method: 'desktopPet/plugins/list',
      params: {},
    })}\n`)
    return
  }
  if (frame.id === 'desktop-pet-build-smoke-plugins') {
    if (frame.error !== undefined) {
      fail(`Packaged Agent plugin snapshot failed: ${JSON.stringify(frame.error)}`)
      return
    }
    const toolNames = Array.isArray(frame.result?.toolNames) ? frame.result.toolNames : null
    const skillNames = Array.isArray(frame.result?.skillNames) ? frame.result.skillNames : null
    if (toolNames === null || skillNames === null) {
      fail(`Packaged Agent returned an invalid plugin snapshot: ${JSON.stringify(frame.result)}`)
      return
    }
    const requiredTools = ['skill', 'todo_write']
    const disabledTools = ['create_goal', 'get_goal', 'update_goal', 'web_search']
    if (!requiredTools.every(name => toolNames.includes(name)) ||
        disabledTools.some(name => toolNames.includes(name))) {
      fail(`Packaged Agent plugin snapshot did not match default flags: ${JSON.stringify(toolNames)}`)
      return
    }
    pluginSnapshotReceived = true
    child.stdin.write(`${JSON.stringify({
      jsonrpc: '2.0',
      id: 'desktop-pet-build-smoke-prompt',
      method: 'session/prompt',
      params: {
        sessionId: 'desktop-pet-build-smoke-session',
        contentBlocks: [{ type: 'text', text: 'Reply using the local smoke response.' }],
      },
    })}\n`)
    return
  }
  if (frame.id === 'desktop-pet-build-smoke-prompt' && frame.error !== undefined) {
    fail(`Packaged Agent prompt failed: ${JSON.stringify(frame.error)}`)
    return
  }
  if (frame.method === 'session.status' &&
      frame.params?.sessionId === 'desktop-pet-build-smoke-session' &&
      frame.params?.status === 'idle') {
    promptCompleted = true
    child.stdin.end()
  }
}

child.stdout.setEncoding('utf8')
child.stdout.on('data', chunk => {
  stdoutBuffer += chunk
  let newline
  while ((newline = stdoutBuffer.indexOf('\n')) !== -1) {
    const line = stdoutBuffer.slice(0, newline).replace(/\r$/, '')
    stdoutBuffer = stdoutBuffer.slice(newline + 1)
    handleLine(line)
  }
})
child.stderr.setEncoding('utf8')
child.stderr.on('data', chunk => {
  stderr += chunk
  if (stderr.length > 64 * 1024) stderr = stderr.slice(-64 * 1024)
})
child.on('error', error => fail(`Could not start packaged Agent: ${error.message}`))
child.on('close', code => {
  if (settled) return
  if (!initialized) {
    fail(`Packaged Agent exited before initialization (exit code ${String(code)}).`)
    return
  }
  if (!pluginSnapshotReceived || !promptCompleted || mockRequestCount === 0 || !mockAuthorizationValid) {
    fail('Packaged Agent did not complete the loopback prompt smoke test.')
    return
  }
  if (code !== 0) {
    fail(`Packaged Agent exited after initialization with code ${String(code)}.`)
    return
  }
  settled = true
  clearTimeout(timeout)
  mockServer.close()
  process.stdout.write('Packaged Windows Agent prompt smoke test passed without a real API key.\n')
})

const timeout = setTimeout(() => {
  fail('Packaged Agent prompt smoke test timed out after 30 seconds.')
}, 30_000)

child.stdin.write(`${JSON.stringify({
  jsonrpc: '2.0',
  id: 'desktop-pet-build-smoke-initialize',
  method: 'initialize',
  params: {
    cwd: workspace,
    provider: 'deepseek-official',
    model: 'deepseek-v4-flash',
    maxTokens: 8192,
  },
})}\n`)
